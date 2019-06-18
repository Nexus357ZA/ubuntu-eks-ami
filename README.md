# ubuntu-eks-ami
Packer configuration for building a custom EKS AMI
# Ubuntu based Amazon EKS AMI Build 

This repository contains resources and configuration scripts for building a
custom Ubuntu 18.04 based Amazon EKS AMI with [HashiCorp Packer](https://www.packer.io/).
This is based on [Amazon EKS AMI Build Specification](https://github.com/awslabs/amazon-eks-ami)
which is the same configuration that Amazon EKS uses to create the official Amazon
EKS-optimized AMI. Changes were made

## Setup

You must have [Packer](https://www.packer.io/) installed on your local system.
For more information, see [Installing Packer](https://www.packer.io/docs/install/index.html)
in the Packer documentation. You must also have AWS account credentials
configured so that Packer can make calls to AWS API operations on your behalf.
For more information, see [Authentication](https://www.packer.io/docs/builders/amazon.html#specifying-amazon-credentials)
in the Packer documentation.

**Note**
The default instance type to build this AMI is an `m4.large` and does not
qualify for the AWS free tier. You are charged for any instances created
when building this AMI.

## Building the AMI

Run Packer with the `eks-worker-ubuntu1804.json` build specification
template and the [amazon-ebs](https://www.packer.io/docs/builders/amazon-ebs.html)
builder. An instance is launched and the Packer [Shell
Provisioner](https://www.packer.io/docs/provisioners/shell.html) runs the
`install-worker.sh` script on the instance to install software and perform other
necessary configuration tasks.  Then, Packer creates an AMI from the instance
and terminates the instance after the AMI is created.
