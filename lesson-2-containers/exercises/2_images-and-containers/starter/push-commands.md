# Push commands for test-containers

## macOS / Linux

### Make sure that you have the latest version of the AWS CLI and Docker installed. For more information, see [Getting started with Amazon ECR.](https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html)

#### [Use the following steps to authenticate and push an image to your repository. For additional registry authentication methods, including the Amazon ECR credential helper, see Registry authentication.](https://docs.aws.amazon.com/AmazonECR/latest/userguide/Registries.html#registry_auth)

1. Retrieve an authentication token and authenticate your Docker client to your registry. Use the AWS CLI:
`aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 738975265234.dkr.ecr.us-east-1.amazonaws.com`

    - Note: if you receive an error using the AWS CLI, make sure that you have the latest version of the AWS CLI and Docker installed.

2. Build your Docker image using the following command. For information on building a Docker file from scratch, see the instructions [here](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/create-container-image.html) . You can skip this step if your image has already been built:
`docker build -t test-containers .`

3. After the build is completed, tag your image so you can push the image to this repository:
`docker tag test-containers:latest 738975265234.dkr.ecr.us-east-1.amazonaws.com/test-containers:latest`

4. Run the following command to push this image to your newly created AWS repository:
`docker push 738975265234.dkr.ecr.us-east-1.amazonaws.com/test-containers:latest`


## Windows

### Make sure that you have the latest version of the AWS TOOLS for PowerShell and Docker installed. For more information, see [Getting started with Amazon ECR.](https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html)

### Use the following steps to authenticate and push an image to your repository. For additional registry authentication methods, including the Amazon ECR credential helper, see [Registry authentication.](https://docs.aws.amazon.com/AmazonECR/latest/userguide/Registries.html#registry_auth)

1. Retrieve an authentication token and authenticate your Docker client to your registry. Use the AWS TOOLS for PowerShell:
`(Get-ECRLoginCommand).Password | docker login --username AWS --password-stdin 738975265234.dkr.ecr.us-east-1.amazonaws.com`

    - Note: if you receive an error using the AWS TOOLS for PowerShell, make sure that you have the latest version of the AWS TOOLS for PowerShell and Docker installed.

2. Build your Docker image using the following command. For information on building a Docker file from scratch, see the instructions here . You can skip this step if your image has already been built:
`docker build -t test-containers .`

3. After the build is completed, tag your image so you can push the image to this repository:
`docker tag test-containers:latest 738975265234.dkr.ecr.us-east-1.amazonaws.com/test-containers:latest`

4. Run the following command to push this image to your newly created AWS repository:
`docker push 738975265234.dkr.ecr.us-east-1.amazonaws.com/test-containers:latest`