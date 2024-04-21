# Cluster CSI Driver Cleanup Script

This Bash script facilitates the cleanup of resources associated with the Cluster CSI Driver and related components in an OpenShift environment. It's particularly useful when decommissioning or resetting a cluster.

## Features

- **Interactive**: The script prompts the user for necessary input, such as the Cluster Name and ROSA VPC ID, to customize resource cleanup.
- **Modular Design**: Functions are used to modularize the script, enhancing readability and maintainability.
- **Error Handling**: Error handling is implemented using `set -euo pipefail`, ensuring robustness in case of unexpected issues.
- **AWS CLI Integration**: AWS CLI commands are used to manage AWS resources, such as IAM roles, policies, and security groups.
- **OpenShift Integration**: The script interacts with OpenShift through the `oc` command-line tool to manage Kubernetes resources like secrets, storage classes, and subscriptions.

## Prerequisites

Before running the script, ensure you have the following:

- AWS CLI configured with appropriate permissions to manage IAM and EC2 resources.
- OpenShift CLI (`oc`) installed and configured to interact with your OpenShift cluster.

## Usage

1. **Clone the Repository**:

    ```bash
    git clone https://github.com/rh-fran6/aws-sts-efs-intall.git
    cd your-repo
    ```

2. **Run the Script**:

    ```bash
    ./cleanup_script.sh
    ```

3. **Follow the Prompts**: The script will prompt you to enter the Cluster Name and ROSA VPC ID as required.

4. **Review Output**: The script will provide feedback on each step of the cleanup process, ensuring transparency and visibility into the performed actions.

## Important Notes

- **Exercise Caution**: Ensure that you understand the implications of running the script, as it will delete various resources associated with the Cluster CSI Driver and related components.
- **Customization**: Feel free to customize the script according to your specific environment or requirements by modifying the function implementations or adding/removing steps as needed.

## Contributions

Contributions are welcome! If you find any issues or have suggestions for improvements, please feel free to open an issue or submit a pull request.

## License

This project is licensed under the [MIT License](LICENSE).
