## Test Premise
1. You need to copy the 'contracts' folder from the repository to the 'brownie/contracts/' directory in the current project, and rename it to 'system_contracts'.
2. You need to navigate to the 'brownie' directory and perform the operation.

## repository address:
https://github.com/coredao-org/core-genesis-contract/tree/master/contracts

## Preparation
Install dependency:
```shell script
cd brownie

pip install -r requirements.txt

npm install
```

## Run Tests
```shell
# change path
cd brownie

# generate contracts for testing
./generate-test-contracts.sh

# run brownie tests
brownie test -v --stateful false 
```

