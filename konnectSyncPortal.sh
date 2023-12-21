# Environment variable
KONNECT_CONTROL_PLANE="test"
KONNECT_TOKEN=kpat_XXXXX
KONG_PROXY_URL_PROD="http://kong-api.com"
KONG_PROXY_URL_TEST="http://kong-api-test.com"


# Pipeline Variable
AUTO_APPROVED="true"
API_ACCESS="external"
API_SWAGGER_URL="https://petstore3.swagger.io/api/v3/openapi.json"


# Start of the script
API_SPEC_FILE="swagger.json"
curl -sL $API_SWAGGER_URL -o $API_SPEC_FILE
deck file openapi2kong -o konnect.yaml -s $API_SPEC_FILE

SERVICE_NAME=$(yq e '.services[].name' konnect.yaml)

# Iterate through each YAML file in the folder
for yamlfile in plugins/*.yaml; do
  # Update the service value using deck file patch
  deck file patch -s "$yamlfile" -o "$yamlfile" --selector '$..plugins[*]' --value 'service: "'$SERVICE_NAME'"'
done

API_PRODUCT_NAME=$API_ACCESS"--"$SERVICE_NAME
PORTAL_PUBLISH="true"
deck file patch -s konnect.yaml -o konnect.yaml --selector '.services[*]' --value 'enabled: false'
deck gateway sync ./plugins konnect.yaml --konnect-addr "https://eu.api.konghq.com" --konnect-token $KONNECT_TOKEN --konnect-control-plane-name $KONNECT_CONTROL_PLANE --select-tag $SERVICE_NAME

if [ "$?" -eq 0 ]; then
  # create API product; update it if it exists

  yq -i e '.servers[0].url |= "'"$KONG_PROXY_URL_PROD"'"' $API_SPEC_FILE -o json
  yq -i e '.servers[0].description |= "Kong Production API Gateway Interface"' $API_SPEC_FILE -o json

  yq -i e '.servers[1].url |= "'"$KONG_PROXY_URL_TEST"'"' $API_SPEC_FILE -o json
  yq -i e '.servers[1].description |= "Kong Test API Gateway Interface"' $API_SPEC_FILE -o json

  # export API_NAME=$(jq -r '.info.title' $API_SPEC_FILE)
  API_DESCRIPTION=$(jq -r '.info.description // "description missing"' "$API_SPEC_FILE" | tr -d '\n')
  API_VERSION=$(jq -r '.info.version' $API_SPEC_FILE)

  CURRENT_PRODUCT_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" https://eu.api.konghq.com/v2/api-products -H "Content-Type: application/json" | jq -r '.data[] | select(.name == "'$API_PRODUCT_NAME'").id')
  if [ -z "$CURRENT_PRODUCT_ID" ]; then
    echo "> $API_PRODUCT_NAME not found already in API Products - creating it..."
    CURRENT_PRODUCT_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X POST https://eu.api.konghq.com/v2/api-products -d '{"name": "'"$API_PRODUCT_NAME"'", "description": "'"$API_DESCRIPTION"'"}' | jq -r '.id')
  else
    echo "> $API_PRODUCT_NAME already exists with ID $CURRENT_PRODUCT_ID"
    curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X PATCH https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID -d '{"name": "'"$API_PRODUCT_NAME"'", "description": "'"$API_DESCRIPTION"'"}' > /dev/null 2>&1
  fi

  # create product version if it doesn't exist
  CURRENT_PRODUCT_VERSION_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" "https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions?filter%5Bname%5D="$API_VERSION | jq -r '.data[0].id')
  if [ "$CURRENT_PRODUCT_VERSION_ID" == "null" ]; then
    echo "> Version $API_VERSION not found already in API Versions for $API_PRODUCT_NAME - creating it..."
    CURRENT_PRODUCT_VERSION_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X POST https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions -d '{"name": "'"$API_VERSION"'"}' | jq -r '.id')
  else
    echo "> API $API_PRODUCT_NAME already has a version with ID $CURRENT_PRODUCT_VERSION_ID - overwriting it"
    CURRENT_PRODUCT_VERSION_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X PATCH https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions/$CURRENT_PRODUCT_VERSION_ID -d '{"name": "'"$API_VERSION"'"}' | jq -r '.id')
  fi

  # retrieve RG and Service ID
  CONTROL_PLANE_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" "https://eu.api.konghq.com/v2/control-planes?filter%5Bname%5D=$KONNECT_CONTROL_PLANE" | jq -r '.data[0].id')
  SERVICE_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" https://eu.api.konghq.com/v2/control-planes/$CONTROL_PLANE_ID/core-entities/services | jq -r '.data[] | select(.name == "'"$SERVICE_NAME"'") | .id')

  # upload the spec into this version, might as well overwrite the old one
  CURRENT_API_SPEC_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions/$CURRENT_PRODUCT_VERSION_ID/specifications | jq -r '.data[0].id')
  if [ "$CURRENT_API_SPEC_ID" == "null" ]; then
    echo "> Publishing spec document for API version $CURRENT_PRODUCT_VERSION_ID"
    curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X POST https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions/$CURRENT_PRODUCT_VERSION_ID/specifications -d '{"name": "oas.yaml", "content": "'"$(cat $API_SPEC_FILE | base64 | tr -d '\n')"'"}' > /dev/null 2>&1
  else
    echo "> API version $CURRENT_PRODUCT_VERSION_ID already has an API spec published - overwriting it"
    curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X PATCH https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions/$CURRENT_PRODUCT_VERSION_ID/specifications/$CURRENT_API_SPEC_ID -d '{"name": "oas.yaml", "content": "'"$(cat $API_SPEC_FILE | base64 | tr -d '\n')"'"}' > /dev/null 2>&1
  fi

  # create gateway service
  CURRENT_PRODUCT_VERSION_GATEWAY_SERVICE_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions/$CURRENT_PRODUCT_VERSION_ID | jq -r '.gateway_service.id')
  if [ "$CURRENT_PRODUCT_VERSION_GATEWAY_SERVICE_ID" == "null" ]; then
    echo "> Gateway Service not found already in API Versions $API_VERSION for $API_PRODUCT_NAME - creating it..."
    CURRENT_PRODUCT_VERSION_GATEWAY_SERVICE_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X PATCH "https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions/$CURRENT_PRODUCT_VERSION_ID" -d '{"gateway_service": { "id": "'"$SERVICE_ID"'", "control_plane_id": "'"$CONTROL_PLANE_ID"'"}}' | jq -r '.gateway_service.id')
    if [ "$CURRENT_PRODUCT_VERSION_GATEWAY_SERVICE_ID" == "null" ]; then
      echo "> Issue linking the gateway service check if another api products is not link to this service already"
      exit 1
    fi
  else
    echo "> Gateway for this version $API_VERSION already exists for API $API_PRODUCT_NAME with ID $CURRENT_PRODUCT_VERSION_GATEWAY_SERVICE_ID"
  fi

  # update portal publication settings
  echo "> Updating version $API_VERSION Portal publication status"
  curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X PATCH https://eu.api.konghq.com/v2/api-products/$CURRENT_PRODUCT_ID/product-versions/$CURRENT_PRODUCT_VERSION_ID -d '{"deprecated": false, "publish_status": "published"}' > /dev/null 2>&1

  PORTAL_ID=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" https://eu.api.konghq.com/v2/portals | jq -r '.data[0].id')
  if [ "$PORTAL_PUBLISH" == "true" ]; then
    echo "> Publish Portal"
    curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X PUT https://eu.api.konghq.com/konnect-api/api/service_packages/$CURRENT_PRODUCT_ID/portals/$PORTAL_ID > /dev/null 2>&1
  else
    echo "> Unpublish Portal"
    curl -s -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -X DELETE https://eu.api.konghq.com/konnect-api/api/service_packages/$CURRENT_PRODUCT_ID/portals/$PORTAL_ID > /dev/null 2>&1
  fi

fi

AUTH_CONFIG=$(curl -s -X PUT "https://eu.api.konghq.com/konnect-api/api/application_registrations/service_versions/$CURRENT_PRODUCT_VERSION_ID" -H "Authorization: Bearer $KONNECT_TOKEN" -H "Content-Type: application/json" -d '{"auth_config": {"name": "key-auth", "config": {}}, "auto_approve": '$AUTO_APPROVED'}' | jq -r '.auth_config.name')

if [ "$AUTH_CONFIG" == "key-auth" ] && [ "$?" -eq 0 ]; then
  echo "> Auth config $AUTH_CONFIG is on so enabling the service"
  deck file patch -s konnect.yaml -o konnect.yaml --selector '.services[*]' --value 'enabled: true'
  deck gateway sync ./plugins konnect.yaml --konnect-addr "https://eu.api.konghq.com" --konnect-token $KONNECT_TOKEN --konnect-control-plane-name $KONNECT_CONTROL_PLANE --select-tag $SERVICE_NAME
fi
