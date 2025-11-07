// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVickreyAuction_NFT {
    
    // ----------------------
    // Events
    // ----------------------
    event AuctionEnded(address winner, uint256 highestBid);
    event AuctionFailed(address indexed nftContract, uint256 indexed tokenId, address indexed seller);
    event AuctionStarted(
        address indexed nftContract,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 biddingEnd,
        uint256 revealEnd,
        uint256 reservePrice,
        address beneficiary
    );
    event NFTDeposited(address indexed depositor, address indexed nftContract, uint256 indexed tokenId);
    event NFTTransferredToWinner(address indexed winner, address indexed nftContract, uint256 indexed tokenId);
    event NFTWithdrawnByDepositor(address indexed depositor, address indexed nftContract, uint256 indexed tokenId);

    // ----------------------
    // View functions
    // ----------------------
    function AuctionResult() external view returns (string memory);
    function BidTime() external view returns (string memory);
    function RevealTime() external view returns (string memory);
    function SellerInfo() external view returns (string memory);
    function reservePrice() external view returns (uint256);

    // ----------------------
    // State-changing functions
    // ----------------------
    function NewAuction(
        uint256 _biddingTime,
        uint256 _revealTime,
        uint256 _reservePrice,
        address payable _Beneficiary,
        address _nftContract,
        uint256 _nftTokenId
    ) external;

    function bid(bytes32 _blindedBid) external payable;
    function reveal(uint256[] calldata _values, string[] calldata _secrets) external;
    function EndAuction() external;
    function withdraw() external;
}
