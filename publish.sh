# This script will perform the following tasks:
#   1. Remove any old build files from previous runs.
#   2. Create a deployment S3 bucket to store build artifacts if not already existing
#   3. Installing required libraries and package them into ZIP files for Lambda layer creation. It will spin up a Docker container to install the packages to ensure architecture compatibility
#   4. Package the CloudFormation template and upload it to the S3 bucket
#
# To deploy to non-default region, set AWS_DEFAULT_REGION to supported region
# See: https://docs.aws.amazon.com/solutions/latest/qnabot-on-aws/supported-aws-regions.html - E.g.
# export AWS_DEFAULT_REGION=eu-west-1

USAGE="$0 <cfn_bucket> <cfn_prefix> [public]"

BUCKET=$1
[ -z "$BUCKET" ] && echo "Cfn bucket name is required parameter. Usage $USAGE" && exit 1

PREFIX=$2
[ -z "$PREFIX" ] && echo "Prefix is required parameter. Usage $USAGE" && exit 1

# Remove trailing slash from prefix if needed
[[ "${PREFIX}" == */ ]] && PREFIX="${PREFIX%?}"

ACL=$3
if [ "$ACL" == "public" ]; then
  echo "Published S3 artifacts will be acessible by public (read-only)"
  PUBLIC=true
else
  echo "Published S3 artifacts will NOT be acessible by public."
  PUBLIC=false
fi

# Config
LAYERS_DIR=$PWD/layers
LAMBDAS_DIR=$PWD/lambdas

# Create bucket if it doesn't already exist
echo "------------------------------------------------------------------------------"
aws s3api list-buckets --query 'Buckets[].Name' | grep "\"$BUCKET\"" > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "Creating S3 bucket: $BUCKET"
  aws s3 mb s3://${BUCKET} || exit 1
  aws s3api put-bucket-versioning --bucket ${BUCKET} --versioning-configuration Status=Enabled || exit 1
else
  echo "Using existing bucket: $BUCKET"
fi
echo "------------------------------------------------------------------------------"


# get bucket region for owned accounts
region=$(aws s3api get-bucket-location --bucket $BUCKET --query "LocationConstraint" --output text) || region="us-east-1"
[ -z "$region" -o "$region" == "None" ] && region=us-east-1;
echo "Bucket in region: $region"

if $PUBLIC; then
    echo "Enabling ACLs on bucket"
    aws s3api put-public-access-block --bucket ${BUCKET} --public-access-block-configuration "BlockPublicPolicy=false"
    aws s3api put-bucket-ownership-controls --bucket ${BUCKET} --ownership-controls="Rules=[{ObjectOwnership=BucketOwnerPreferred}]"
fi

echo "------------------------------------------------------------------------------"
echo "Installing Python packages for AWS Lambda Layers"
echo "------------------------------------------------------------------------------"
if [ -d "$LAYERS_DIR" ]; then
  LAYERS=$(ls $LAYERS_DIR)
  pushd $LAYERS_DIR
  for layer in $LAYERS; do
    echo "Installing packages for: $layer"
    # ref docs: https://docs.aws.amazon.com/lambda/latest/dg/python-package.html#python-package-pycache
    pip install \
    --quiet \
    --platform manylinux2014_x86_64 \
    --target=package \
    --implementation cp \
    --python-version 3.10 \
    --only-binary=:all: \
    --no-compile \
    --requirement ${layer}/requirements.txt \
    --target=${layer}/python 2>&1 | \
      grep -v "WARNING: Target directory"
    echo "Done installing dependencies for $layer"
  done
  popd
else
  echo "Directory $LAYERS_DIR does not exist. Skipping"
fi

echo "------------------------------------------------------------------------------"
echo "Packaging CloudFormation artifacts"
echo "------------------------------------------------------------------------------"
LAMBDAS=$(ls $LAMBDAS_DIR)
for lambda in $LAMBDAS; do
  dir=$LAMBDAS_DIR/$lambda
  pushd $dir
  echo "PACKAGING $lambda"
  mkdir -p ./out
  template=${lambda}.yaml
  s3_template=s3://${BUCKET}/${PREFIX}/${template}
  https_template="https://s3.${region}.amazonaws.com/${BUCKET}/${PREFIX}/${template}"
  # avoid re-packaging source zips if only file timestamps have changed - per https://blog.revolve.team/2022/05/19/lambda-build-consistency/
  [ -d "$LAYERS_DIR" ] && sudo find $LAYERS_DIR -exec touch -a -m -t"202307230000.00" {} \;
  sudo find ./src -exec touch -a -m -t"202307230000.00" {} \;
  aws cloudformation package \
  --template-file ./template.yml \
  --output-template-file ./out/${template} \
  --s3-bucket $BUCKET --s3-prefix $PREFIX \
  --region ${region} || exit 1
  echo "Uploading template file to: ${s3_template}"
  aws s3 cp ./out/${template} ${s3_template}
  echo "Validating template"
  aws cloudformation validate-template --template-url ${https_template} > /dev/null || exit 1
  popd
done

if $PUBLIC; then
  echo "------------------------------------------------------------------------------"
  echo "Setting public read ACLs on published artifacts"
  echo "------------------------------------------------------------------------------"
  files=$(aws s3api list-objects --bucket ${BUCKET} --prefix ${PREFIX} --query "(Contents)[].[Key]" --output text)
  for file in $files
    do
    aws s3api put-object-acl --acl public-read --bucket ${BUCKET} --key $file
    done
fi

echo "------------------------------------------------------------------------------"
echo "Outputs"
echo "------------------------------------------------------------------------------"
for lambda in $LAMBDAS; do
  stackname=QNABOTPLUGIN-$(echo $lambda | tr '[:lower:]' '[:upper:]' | tr '_' '-')
  template="https://s3.${region}.amazonaws.com/${BUCKET}/${PREFIX}/${lambda}.yaml"
  echo $stackname
  echo "=============="
  echo " - Template URL: $template"
  echo " - Deploy URL:   https://${region}.console.aws.amazon.com/cloudformation/home?region=${region}#/stacks/create/review?templateURL=${template}&stackName=${stackname}"
  echo ""
done
echo "All done!"
exit 0
