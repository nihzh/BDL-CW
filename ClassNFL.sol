// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract ClassNFT is ERC721URIStorage, Ownable, Pausable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIds;

    constructor() 
        ERC721("ClassNFT", "CNFT") 
        Ownable(msg.sender)
        {}


    // The main function to mint a new NFT.
    // It automatically mints the NFT to the person who calls the function.
    // 'uri' is the metadata link for the NFT.
    function safeMint(string memory uri) public returns (uint256) {
        uint256 tokenId = _tokenIds.current();
        _safeMint(msg.sender, tokenId); // Mints to the caller's address
        _setTokenURI(tokenId, uri);
        _tokenIds.increment();
        return tokenId;
    }

    // The owner can pause the contract if needed.
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

}