#!/bin/bash

##############################################################################
# Lambda Function Cloner Script
# Clones Lambda functions with code, layers, environment variables, and IAM roles
# Usage: ./clone-lambda.sh <SOURCE_FUNCTION_NAME> <NEW_FUNCTION_NAME> [AWS_REGION]
# Example: ./clone-lambda.sh my-function my-function-manual us-east-1
##############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
SOURCE_FUNCTION=$1
NEW_FUNCTION=$2
AWS_REGION=${3:-us-east-1}

if [ -z "$SOURCE_FUNCTION" ] || [ -z "$NEW_FUNCTION" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo "Usage: $0 <SOURCE_FUNCTION_NAME> <NEW_FUNCTION_NAME> [AWS_REGION]"
    echo "Example: $0 my-function my-function-manual us-east-1"
    exit 1
fi

# Create working directory
WORK_DIR="./lambda-clone-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo -e "${GREEN}=== Lambda Function Cloner ===${NC}"
echo "Source Function: $SOURCE_FUNCTION"
echo "New Function: $NEW_FUNCTION"
echo "Region: $AWS_REGION"
echo "Working Directory: $WORK_DIR"
echo ""

##############################################################################
# STEP 1: Get Source Lambda Configuration
##############################################################################
echo -e "${YELLOW}Step 1: Fetching source Lambda configuration...${NC}"

# Check if source function exists
if ! aws lambda get-function --function-name "$SOURCE_FUNCTION" --region "$AWS_REGION" &>/dev/null; then
    echo -e "${RED}Error: Source function '$SOURCE_FUNCTION' not found in region $AWS_REGION${NC}"
    exit 1
fi

# Get full function configuration
aws lambda get-function \
    --function-name "$SOURCE_FUNCTION" \
    --region "$AWS_REGION" \
    > source-function.json

echo -e "${GREEN}✓ Configuration retrieved${NC}"

# Extract configuration details
RUNTIME=$(jq -r '.Configuration.Runtime' source-function.json)
HANDLER=$(jq -r '.Configuration.Handler' source-function.json)
ROLE_ARN=$(jq -r '.Configuration.Role' source-function.json)
TIMEOUT=$(jq -r '.Configuration.Timeout' source-function.json)
MEMORY=$(jq -r '.Configuration.MemorySize' source-function.json)
DESCRIPTION=$(jq -r '.Configuration.Description // "Cloned from '"$SOURCE_FUNCTION"'"' source-function.json)
EPHEMERAL_STORAGE=$(jq -r '.Configuration.EphemeralStorage.Size // 512' source-function.json)

# Get environment variables
ENV_VARS=$(jq -r '.Configuration.Environment.Variables // {}' source-function.json)

# Get VPC configuration if exists
VPC_CONFIG=$(jq -r '.Configuration.VpcConfig // {}' source-function.json)
HAS_VPC=$(echo "$VPC_CONFIG" | jq -r 'has("SubnetIds") and (.SubnetIds | length > 0)')

# Get layers
LAYERS=$(jq -r '.Configuration.Layers // [] | map(.Arn) | join(" ")' source-function.json)

# Get architectures
ARCHITECTURES=$(jq -r '.Configuration.Architectures // ["x86_64"] | join(",")' source-function.json)

echo ""
echo -e "${BLUE}Source Function Details:${NC}"
echo "  Runtime: $RUNTIME"
echo "  Handler: $HANDLER"
echo "  Role: $ROLE_ARN"
echo "  Timeout: ${TIMEOUT}s"
echo "  Memory: ${MEMORY}MB"
echo "  Ephemeral Storage: ${EPHEMERAL_STORAGE}MB"
echo "  Architecture: $ARCHITECTURES"
if [ "$HAS_VPC" == "true" ]; then
    echo "  VPC: Enabled"
fi
if [ -n "$LAYERS" ]; then
    echo "  Layers: $(echo "$LAYERS" | wc -w) layer(s)"
fi
echo ""

##############################################################################
# STEP 2: Download Function Code
##############################################################################
echo -e "${YELLOW}Step 2: Downloading function code...${NC}"

CODE_LOCATION=$(jq -r '.Code.Location' source-function.json)
curl -s "$CODE_LOCATION" -o "${SOURCE_FUNCTION}.zip"

FILE_SIZE=$(du -h "${SOURCE_FUNCTION}.zip" | cut -f1)
echo -e "${GREEN}✓ Code downloaded (${FILE_SIZE})${NC}"

##############################################################################
# STEP 3: Check if New Function Already Exists
##############################################################################
echo ""
echo -e "${YELLOW}Step 3: Checking if target function exists...${NC}"

FUNCTION_EXISTS=false
if aws lambda get-function --function-name "$NEW_FUNCTION" --region "$AWS_REGION" &>/dev/null; then
    FUNCTION_EXISTS=true
    echo -e "${YELLOW}Function '$NEW_FUNCTION' already exists.${NC}"
    read -p "Do you want to UPDATE it? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

##############################################################################
# STEP 4: Create or Update Lambda Function
##############################################################################
echo ""
if [ "$FUNCTION_EXISTS" = true ]; then
    echo -e "${YELLOW}Step 4: Updating existing Lambda function...${NC}"
    
    # Update function code
    echo "  Updating code..."
    aws lambda update-function-code \
        --function-name "$NEW_FUNCTION" \
        --zip-file "fileb://${SOURCE_FUNCTION}.zip" \
        --region "$AWS_REGION" \
        > update-code-response.json
    
    # Wait for update to complete
    echo "  Waiting for code update to complete..."
    aws lambda wait function-updated \
        --function-name "$NEW_FUNCTION" \
        --region "$AWS_REGION"
    
    # Build configuration update command
    UPDATE_CONFIG_CMD="aws lambda update-function-configuration \
        --function-name \"$NEW_FUNCTION\" \
        --runtime \"$RUNTIME\" \
        --handler \"$HANDLER\" \
        --role \"$ROLE_ARN\" \
        --timeout $TIMEOUT \
        --memory-size $MEMORY \
        --ephemeral-storage Size=$EPHEMERAL_STORAGE \
        --description \"$DESCRIPTION\" \
        --region \"$AWS_REGION\""
    
    # Add environment variables if they exist
    if [ "$ENV_VARS" != "{}" ]; then
        UPDATE_CONFIG_CMD="$UPDATE_CONFIG_CMD --environment '$(jq -n --argjson vars "$ENV_VARS" '{"Variables": $vars}')'"
    fi
    
    # Add layers if they exist
    if [ -n "$LAYERS" ]; then
        LAYERS_ARRAY=$(echo "$LAYERS" | tr ' ' ',')
        UPDATE_CONFIG_CMD="$UPDATE_CONFIG_CMD --layers $LAYERS_ARRAY"
    fi
    
    # Add VPC configuration if exists
    if [ "$HAS_VPC" == "true" ]; then
        SUBNET_IDS=$(echo "$VPC_CONFIG" | jq -r '.SubnetIds | join(",")')
        SECURITY_GROUP_IDS=$(echo "$VPC_CONFIG" | jq -r '.SecurityGroupIds | join(",")')
        UPDATE_CONFIG_CMD="$UPDATE_CONFIG_CMD --vpc-config SubnetIds=$SUBNET_IDS,SecurityGroupIds=$SECURITY_GROUP_IDS"
    fi
    
    echo "  Updating configuration..."
    eval "$UPDATE_CONFIG_CMD" > update-config-response.json
    
    # Wait for configuration update to complete
    echo "  Waiting for configuration update to complete..."
    aws lambda wait function-updated \
        --function-name "$NEW_FUNCTION" \
        --region "$AWS_REGION"
    
    echo -e "${GREEN}✓ Function updated successfully${NC}"
    
else
    echo -e "${YELLOW}Step 4: Creating new Lambda function...${NC}"
    
    # Build create function command
    CREATE_CMD="aws lambda create-function \
        --function-name \"$NEW_FUNCTION\" \
        --runtime \"$RUNTIME\" \
        --role \"$ROLE_ARN\" \
        --handler \"$HANDLER\" \
        --zip-file \"fileb://${SOURCE_FUNCTION}.zip\" \
        --timeout $TIMEOUT \
        --memory-size $MEMORY \
        --ephemeral-storage Size=$EPHEMERAL_STORAGE \
        --description \"$DESCRIPTION\" \
        --architectures $ARCHITECTURES \
        --region \"$AWS_REGION\""
    
    # Add environment variables if they exist
    if [ "$ENV_VARS" != "{}" ]; then
        CREATE_CMD="$CREATE_CMD --environment '$(jq -n --argjson vars "$ENV_VARS" '{"Variables": $vars}')'"
    fi
    
    # Add layers if they exist
    if [ -n "$LAYERS" ]; then
        LAYERS_ARRAY=$(echo "$LAYERS" | tr ' ' ',')
        CREATE_CMD="$CREATE_CMD --layers $LAYERS_ARRAY"
    fi
    
    # Add VPC configuration if exists
    if [ "$HAS_VPC" == "true" ]; then
        SUBNET_IDS=$(echo "$VPC_CONFIG" | jq -r '.SubnetIds | join(",")')
        SECURITY_GROUP_IDS=$(echo "$VPC_CONFIG" | jq -r '.SecurityGroupIds | join(",")')
        CREATE_CMD="$CREATE_CMD --vpc-config SubnetIds=$SUBNET_IDS,SecurityGroupIds=$SECURITY_GROUP_IDS"
    fi
    
    # Execute create command
    eval "$CREATE_CMD" > create-response.json
    
    # Wait for function to be active
    echo "  Waiting for function to become active..."
    aws lambda wait function-active \
        --function-name "$NEW_FUNCTION" \
        --region "$AWS_REGION"
    
    echo -e "${GREEN}✓ Function created successfully${NC}"
fi

##############################################################################
# STEP 5: Get New Function Details
##############################################################################
echo ""
echo -e "${YELLOW}Step 5: Fetching new function details...${NC}"

aws lambda get-function \
    --function-name "$NEW_FUNCTION" \
    --region "$AWS_REGION" \
    > new-function.json

NEW_FUNCTION_ARN=$(jq -r '.Configuration.FunctionArn' new-function.json)

echo -e "${GREEN}✓ Function ready${NC}"

##############################################################################
# STEP 6: Summary
##############################################################################
echo ""
echo -e "${GREEN}=== Clone Complete ===${NC}"
echo ""
echo "Source Function: $SOURCE_FUNCTION"
echo "New Function: $NEW_FUNCTION"
echo "New Function ARN: $NEW_FUNCTION_ARN"
echo ""
echo -e "${BLUE}Configuration Summary:${NC}"
echo "  Runtime: $RUNTIME"
echo "  Handler: $HANDLER"
echo "  Role: $ROLE_ARN"
echo "  Timeout: ${TIMEOUT}s"
echo "  Memory: ${MEMORY}MB"
if [ -n "$LAYERS" ]; then
    echo "  Layers: $(echo "$LAYERS" | wc -w) layer(s) attached"
fi
if [ "$HAS_VPC" == "true" ]; then
    echo "  VPC: Configured"
fi
if [ "$ENV_VARS" != "{}" ]; then
    echo "  Environment Variables: $(echo "$ENV_VARS" | jq 'length') variable(s)"
fi
echo ""
echo "All files saved in: $WORK_DIR"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Attach this Lambda to your cloned API Gateway"
echo "2. Update API Gateway integration URIs to use: $NEW_FUNCTION_ARN"
echo "3. Test the function: aws lambda invoke --function-name $NEW_FUNCTION output.json --region $AWS_REGION"
echo ""
echo "To delete the function later:"
echo "  aws lambda delete-function --function-name $NEW_FUNCTION --region $AWS_REGION"
echo ""