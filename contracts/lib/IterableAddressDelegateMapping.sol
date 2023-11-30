// SPDX-License-Identifier: Apache2.0
pragma solidity 0.8.4;

import "./Structs.sol";

library IterableAddressDelegateMapping {
    struct Map {
        address[] keys;
        mapping(address => DelegateInfo) values;
        mapping(address => uint) indexOf;
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
        if (map.indexOf[key] != 0) {
            if (increase) {
                map.values[key].amount += val.amount;
                map.values[key].earning += val.earning;
            } else {
                map.values[key].amount -= val.amount;
                map.values[key].earning -= val.earning;
            }
        } else {
            map.values[key] = val;
            map.keys.push(key);
            map.indexOf[key] = map.keys.length;
        }
    }

    function remove(Map storage map, address key) internal {
        if (map.indexOf[key] == 0) {
            return;
        }

        delete map.values[key];

        uint indexPlus1 = map.indexOf[key];
        if (indexPlus1 != map.keys.length) {
            address lastKey = map.keys[map.keys.length - 1];
            map.indexOf[lastKey] = indexPlus1;
            map.keys[indexPlus1 - 1] = lastKey;
        }
        delete map.indexOf[key];
        map.keys.pop();
    }

    function exist(Map storage map, address key) view internal returns(bool) {
        return map.indexOf[key] != 0;
    } 
}