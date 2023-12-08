node js/copy_file.js
node js/generate-system.js --mock true
node js/generate-candidatehub.js --mock true
node js/generate-pledgeagent.js --mock true
node js/generate-validatorset.js --mock true
node js/generate-slash.js -c 1112
node js/generate-btclightclient.js --initConsensusStateBytes 000040209acaa5d26d392ace656c2428c991b0a3d3d773845a1300000000000000000000aa8e225b1f3ea6c4b7afd5aa1cecf691a8beaa7fa1e579ce240e4a62b5ac8ecc2141d9618b8c0b170d5c05bb --initChainHeight 717696
node js/generate-earn.js --mock true