## Run Tests

# You need to copy the "contracts" files from the repository to the "contracts" directory in the current project.
repository address:https://github.com/coredao-org/core-genesis-contract/tree/master/contracts

```shell
# install test dependency
pip install -r requirements.txt

# generate contracts for testing
./generate-test-contracts.sh

# run brownie tests
brownie test -v 
```

