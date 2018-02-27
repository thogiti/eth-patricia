pragma solidity ^0.4.19;

import "./util.sol";
import "./MerklePatriciaProof.sol";
import './RLPEncode.sol';
import "./BytesLib.sol";

// Contract for mirroring needed parts of the blockchain
contract Blockchain is Util {

    mapping (uint => bytes32) block_hash;

    struct BlockData {
        bytes32 stateRoot;
        bytes32 transactionRoot;
        mapping (uint => bytes32) transactions; // element 1 means not found
        mapping (address => bytes32) accounts;  // element 1 means not found
        uint numTransactions;
    }
    
    mapping (bytes32 => BlockData) block_data;

    struct TransactionData {
        address to;
        address sender;
        bytes data;
    }
    
    mapping (bytes32 => TransactionData) transactions;
    
    struct AccountData {
        bytes32 storageRoot;
        mapping (bytes32 => bytes32) stuff;
        mapping (bytes32 => bool) stuff_checked;
    }

    mapping (bytes32 => AccountData) accounts;

    function storeHashes(uint n) public {
        for (uint i = 1; i <= n; i++) block_hash[block.number-i] = block.blockhash(block.number-i);
    }

    function getBytes32(bytes rlp) internal pure returns (bytes32) {
        require(rlp.length == 33);
        bytes32 res;
        assembly {
            res := mload(add(33,rlp))
        }
        return res;
    }

    function getAddress(bytes rlp) internal pure returns (address) {
        if (rlp.length == 0) return 0;
        require(rlp.length == 21);
        return address(readSize(rlp, 1, 20));
    }

    function storeHeader(uint n, bytes header) public {
        // sanity check
        require(rlpArrayLength(header, 0) == 15);
        require(keccak256(header) == block_hash[n]);
        BlockData storage dta = block_data[block_hash[n]];
        dta.stateRoot = getBytes32(rlpFindBytes(header, 3));
        dta.transactionRoot = getBytes32(rlpFindBytes(header, 4));
    }

    function transactionSender(bytes32 hash, bytes tr) public pure returns (address) {
        // w
        uint v = readInteger(rlpFindBytes(tr, 6));
        // r
        uint r = readInteger(rlpFindBytes(tr, 7));
        // s
        uint s = readInteger(rlpFindBytes(tr, 8));
        return ecrecover(hash, uint8(v), bytes32(r), bytes32(s));
    }
    
    function updateNumTransactions(uint blk, uint num) public {
        BlockData storage dta = block_data[block_hash[blk]];
        require(uint(dta.transactions[num]) == 1);
        require(uint(dta.transactions[num-1]) > 1);
        dta.numTransactions = num + 1;
    }

    function storeTransaction(bytes tr) public {
        // read all the fields of transaction
        require(rlpArrayLength(tr, 0) == 9);
        bytes[] memory d = new bytes[](6);
        d[0] = rlpFindBytes(tr, 0); // nonce
        d[1] = rlpFindBytes(tr, 1); // price
        d[2] = rlpFindBytes(tr, 2); // gas
        d[3] = rlpFindBytes(tr, 3); // to
        d[4] = rlpFindBytes(tr, 4); // value
        d[5] = rlpFindBytes(tr, 5); // data
        
        uint len = d[0].length + d[1].length + d[2].length + d[3].length + d[4].length + d[5].length;
        bytes32 hash = keccak256(arrayPrefix(len+3), d[0], d[1], d[2], d[3], d[4], d[5], byte(0x1c), bytes2(0x8080));
        TransactionData storage tr_data = transactions[keccak256(tr)];
        tr_data.sender = transactionSender(hash, tr);
        tr_data.to = getAddress(d[3]);
        tr_data.data = d[5]; // probably should remove RLP prefix
    }

    function storeAccount(bytes rlp) public {
        // read all the fields of account
        require(rlpArrayLength(rlp, 0) == 4);
        AccountData storage a_data = accounts[keccak256(rlp)];
        // 0 nonce
        // 1 balance
        // 2 storage
        // 3 code
        a_data.storageRoot = getBytes32(rlpFindBytes(rlp, 2));
    }
    
    // proof for transaction
    function transactionInBlock(bytes32 txHash, uint num, bytes parentNodes, uint blk) public {
        BlockData storage b = block_data[block_hash[blk]];
        bytes memory path = rlpInteger(num);
        require(MerklePatriciaProof.verify(txHash, path, parentNodes, b.transactionRoot));
        b.transactions[num] = txHash;
    }

    // proof for account
    function accountInBlock(bytes32 aHash, address addr, bytes parentNodes, uint blk) public {
        BlockData storage b = block_data[block_hash[blk]];
        bytes memory path = bytes32ToBytes(keccak256(addr));
        require(MerklePatriciaProof.verify(aHash, path, parentNodes, b.stateRoot));
        b.accounts[addr] = aHash;
    }

    
    // proof for storage
    function storageInAccount(bytes32 aHash, bytes32 data, bytes32 ptr, bytes parentNodes, uint blk) public {
        AccountData storage b = account_data[aHash];
        bytes memory path = bytes32ToBytes(ptr);
        require(MerklePatriciaProof.verify(sHash, path, parentNodes, b.storageRoot));
        b.stuff[ptr] = data;
        b.stuff_checked[ptr] = true;
    }

    // Accessors
    function blockTransactions(uint blk) public view returns (uint) {
        uint num = block_data[block_hash[blk]].numTransactions;
        require (num > 0);
        return num-1;
    }

    function transactionSender(uint blk, uint num) public view returns (address) {
        bytes32 tr_hash = block_data[block_hash[blk]].transactions[num];
        require (uint(tr_hash) > 1);
        TransactionData storage tr = transactions[tr_hash];
        return tr.sender;
    }

    function transactionReceiver(uint blk, uint num) public view returns (address) {
        bytes32 tr_hash = block_data[block_hash[blk]].transactions[num];
        require (uint(tr_hash) > 1);
        TransactionData storage tr = transactions[tr_hash];
        return tr.to;
    }

    function transactionData(uint blk, uint num) public view returns (bytes) {
        bytes32 tr_hash = block_data[block_hash[blk]].transactions[num];
        require (uint(tr_hash) > 1);
        TransactionData storage tr = transactions[tr_hash];
        return tr.data;
    }

    function accountStorage(uint blk, address addr, bytes32 ptr) public view returns (bytes32) {
        bytes32 a_hash = block_data[block_hash[blk]].accounts[addr];
        require (uint(a_hash) > 1);
        AccountData storage a = accounts[a_hash];
        require(a.stuff_checked[ptr]);
        return a.stuff[ptr];
    }

}
