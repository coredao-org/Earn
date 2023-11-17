// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./Structs.sol";

library IterableAddressDelegateMapping {
    struct Map {
        address[] keys;
        mapping(address => DelegateInfo) values;
        mapping(address => uint) indexOf;
        mapping(address => bool) inserted;
    }

    function get(Map storage map, address key) internal view returns (DelegateInfo storage) {
        return map.values[key];
    }

    function getKeyAtIndex(Map storage map, uint index) internal view returns (address) {
        return map.keys[index];
    }

    function size(Map storage map) internal view returns (uint) {
        return map.keys.length;
    }

    function set(Map storage map, address key, DelegateInfo memory val, bool increase) internal {
        if (map.inserted[key]) {
            if (increase) {
                map.values[key].amount += val.amount;
                map.values[key].earning += val.earning;
            } else {
                map.values[key].amount -= val.amount;
                map.values[key].earning -= val.earning;
            }
        } else {
            map.inserted[key] = true;
            map.values[key] = val;
            map.indexOf[key] = map.keys.length;
            map.keys.push(key);
        }
    }

    function remove(Map storage map, address key) internal {
        if (!map.inserted[key]) {
            return;
        }

        delete map.inserted[key];
        delete map.values[key];

        uint index = map.indexOf[key];
        address lastKey = map.keys[map.keys.length - 1];

        map.indexOf[lastKey] = index;
        delete map.indexOf[key];

        map.keys[index] = lastKey;
        map.keys.pop();
    }

    function exist(Map storage map, address key) view internal returns(bool) {
        return map.inserted[key];
    } 
}