// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Simple Vickrey Auction House (Commit–Reveal for ERC-721 on Sepolia)
/// @notice Implements sealed-bid, second-price auctions with deterministic tie-break (earlier commit wins).
/// @dev Single active auction at a time; after an auction ends, anyone can start a new one.
interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 tokenId) external view returns (address);
}

contract VickreyAuctionHouse {
    // --------- Errors ---------
    error NoActiveAuction();
    error AuctionActive();
    error NotSeller();
    error NotInCommitPhase();
    error NotInRevealPhase();
    error CommitAlreadyMade();
    error RevealAlreadyDone();
    error InvalidCommitment();
    error NotFinalizable();
    error NotWinner();
    error WrongPayment();
    error PaymentClosed();
    error NotEnded();
    error NFTNotEscrowed();

    // --------- Restriction Constants ---------
    uint256 private constant _MAX_DURATION = 2592000;  // 30 days
    uint256 private constant _MAX_PRICE = 1e27; // 1_000_000_000 ETH

    // --------- Minimal Reentrancy Guard ---------
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status = _NOT_ENTERED;
    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // --------- Auction Storage ---------
    struct Auction {
        // Item
        IERC721 nft;
        uint256 tokenId;

        // Roles
        address seller;

        // Pricing
        uint256 reservePrice;
        uint256 exceedPrice;

        // Phases (unix seconds)
        uint64 startStamp; // inclusive
        uint64 commitEnd; // exclusive
        uint64 revealEnd; // exclusive

        // Winner settlement
        address highestBidder;
        uint256 highestBid; // value revealed (>= reserve)
        uint256 secondBid;  // second-highest valid revealed value
        uint256 clearingPrice; // max(secondBid, reservePrice)
        bool finalized; // result computed
        bool settled;   // NFT & funds exchanged OR marked unsold

        // For deterministic tie-break (earlier commit wins)
        // and to track per-bidder status
        mapping(address => bytes32) commitments;     // bidder => commitment hash
        mapping(address => uint64)  commitTime;      // bidder => first commit timestamp
        mapping(address => uint256) revealedAmount;  // bidder => revealed valid amount
        uint64 paymentDeadline; // after finalize; winner must pay before this
    }

    uint256 public auctionId; // increments per new auction
    mapping(uint256 => Auction) private _auctions;

    // To keep external view functions simple:
    IERC721 public immutable classNFT; // Sepolia NFT contract from spec
    // If你希望灵活，也可在 startAuction 里传入任意 IERC721；为保持作业一致性，这里固定。
    constructor(address classNFTAddress) {
        require(classNFTAddress != address(0), "bad NFT");
        classNFT = IERC721(classNFTAddress);
    }

    // --------- Events ---------
    event AuctionStarted(
        uint256 indexed id,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        uint256 reservePrice,
        uint256 exceedPrice,
        uint256 startStamp,
        uint64 commitEnd,
        uint64 revealEnd
    );
    event BidCommitted(uint256 indexed id, address indexed bidder);
    event BidRevealed(uint256 indexed id, address indexed bidder, uint256 amount);
    event Finalized(uint256 indexed id, address winner, uint256 highest, uint256 second, uint256 clearingPrice);
    event WinnerPaidAndClaimed(uint256 indexed id, address indexed winner, uint256 price);
    event Unsold(uint256 indexed id);
    event SellerReclaimed(uint256 indexed id);

    // --------- Views (helpers) ---------
    function currentPhase(uint256 id) public view returns (string memory) {
        Auction storage A = _requireAuction(id);
        uint256 t = block.timestamp;
        if (t < A.commitEnd) return "COMMIT";
        if (t < A.revealEnd) return "REVEAL";
        if (!A.finalized) return "FINALIZE_PENDING";
        if (A.finalized && !A.settled && A.highestBidder != address(0) && t <= A.paymentDeadline) return "AWAIT_PAYMENT";
        if (!A.settled) return "SETTLEMENT_OPEN";
        return "ENDED";
    }

    function getWinnerInfo(uint256 id) external view returns (address winner, uint256 price, uint64 payDeadline) {
        Auction storage A = _requireAuction(id);
        return (A.highestBidder, A.clearingPrice, A.paymentDeadline);
    }

    // return set stage timestamps
    function getTimes(uint256 id) external view returns (uint64 commitEnd, uint64 revealEnd, uint64 paymentDeadline) {
        Auction storage A = _requireAuction(id);
        return (A.commitEnd, A.revealEnd, A.paymentDeadline);
    }

    // --------- Core Logic ---------

    /// @notice Start a new auction. Seller must own the NFT and approve this contract; NFT is escrowed in.
    /// @param tokenId Token id in the fixed ClassNFT.
    /// @param reservePrice Minimum acceptable price (wei).
    /// @param commitDurationSeconds Commit phase duration in seconds.
    /// @param revealDurationSeconds Reveal phase duration in seconds.
    function startAuction(
        uint256 tokenId,
        uint256 reservePrice,
        uint256 exceedPrice,
        uint64 commitDurationSeconds,
        uint64 revealDurationSeconds
    ) external {
        // Ensure no active auction (last settled or no auction yet)
        if (auctionId != 0) {
            Auction storage prev = _auctions[auctionId];
            require(prev.settled, "previous not settled");
        }

        // Basic checks
        require(commitDurationSeconds > 0 && commitDurationSeconds < _MAX_DURATION, "CONFIG: bad commit durations");
        require(revealDurationSeconds > 0 && revealDurationSeconds < _MAX_DURATION, "CONFIG: bad reveal durations");
        require(reservePrice >= 0 && reservePrice < _MAX_PRICE, "CONFIG: bad reserve price");
        require(exceedPrice > 0 && exceedPrice <= _MAX_PRICE, "CONFIG: bad exceed price");

        // Must own & approve, then escrow NFT
        require(classNFT.ownerOf(tokenId) == msg.sender, "NFT: not owner");
        // Accept either token-level or operator approval
        require(
            classNFT.getApproved(tokenId) == address(this) || classNFT.isApprovedForAll(msg.sender, address(this)),
            "NFT: not approved"
        );
        classNFT.transferFrom(msg.sender, address(this), tokenId);

        // Create auction
        auctionId += 1;
        Auction storage A = _auctions[auctionId];
        A.nft = classNFT;
        A.tokenId = tokenId;
        A.seller = msg.sender;
        A.reservePrice = reservePrice;
        A.exceedPrice = exceedPrice;

        uint64 nowTs = uint64(block.timestamp);
        A.startStamp = nowTs;
        A.commitEnd = nowTs + commitDurationSeconds;
        A.revealEnd = A.commitEnd + revealDurationSeconds;

        emit AuctionStarted(auctionId, msg.sender, address(classNFT), tokenId, reservePrice, exceedPrice, A.startStamp, A.commitEnd, A.revealEnd);
    }

    /// @notice Commit a bid hash during commit phase. One commit per address（只记录第一次提交时间以用于并列判定）。
    /// @param commitment keccak256(abi.encodePacked(amount, salt))
    function commitBid(bytes32 commitment) external {
        Auction storage A = _requireActiveAuction();
        
        // only commit in commit phase
        if (block.timestamp >= A.commitEnd || block.timestamp < A.startStamp) revert NotInCommitPhase();
        //if (A.commitments[msg.sender] != bytes32(0)) revert CommitAlreadyMade();
        // 如果已经提交过，替换前一个出价
        if (A.commitments[msg.sender] != bytes32(0)) {
            A.commitments[msg.sender] = bytes32(0);
            A.revealedAmount[msg.sender] = 0;
        }
        A.commitments[msg.sender] = commitment;
        // record time for tied price
        A.commitTime[msg.sender] = uint64(block.timestamp);

        emit BidCommitted(auctionId, msg.sender);
    }

    /// @notice Reveal your bid during reveal phase.
    /// @param amount Bid amount in wei.
    /// @param salt The random secret used in commit.
    function revealBid(uint256 amount, bytes32 salt) external {
        Auction storage A = _requireActiveAuction();
        uint256 t = block.timestamp;
        if (t < A.commitEnd || t >= A.revealEnd) revert NotInRevealPhase();

        if (A.revealedAmount[msg.sender] != 0) revert RevealAlreadyDone();

        bytes32 c = A.commitments[msg.sender];
        if (c == bytes32(0)) revert InvalidCommitment();
        if (keccak256(abi.encodePacked(amount, salt)) != c) revert InvalidCommitment();

        // Record revealed amount (0 treated as invalid anyway)
        A.revealedAmount[msg.sender] = amount;

        // Only bids >= reserve are "valid"
        if (amount >= A.reservePrice) {
            // Update top-2 with deterministic tie-break:
            // 1) higher amount wins
            // 2) if equal amount, earlier commitTime wins
            if (
                amount > A.highestBid ||
                (amount == A.highestBid && A.commitTime[msg.sender] < A.commitTime[A.highestBidder])
            ) {
                // push down previous highest into second
                if (A.highestBidder != address(0)) {
                    A.secondBid = A.highestBid;
                }
                A.highestBid = amount;
                A.highestBidder = msg.sender;
            } else if (amount > A.secondBid) {
                // amount <= highestBid here
                A.secondBid = amount;
            }
        }

        emit BidRevealed(auctionId, msg.sender, amount);
    }

    /// @notice Finalize result after reveal ends: compute clearing price or mark unsold.
    ///         Sets a payment deadline for the winner to pay and claim.
    function finalize() external {
        Auction storage A = _requireActiveAuction();
        if (block.timestamp < A.revealEnd) revert NotFinalizable();
        require(!A.finalized, "already finalized");

        if (A.highestBidder == address(0)) {
            // No valid bid >= reserve -> UNSOLD, return NFT to seller
            A.finalized = true;
            A.settled = true;
            A.clearingPrice = 0;
            _safeTransferNFT(A, address(this), A.seller, A.tokenId);
            emit Unsold(auctionId);
            return;
        }

        // Compute second-price clearing
        uint256 clearing = A.secondBid;
        if (clearing < A.reservePrice) clearing = A.reservePrice;

        A.clearingPrice = clearing;
        A.finalized = true;
        // Winner must pay within e.g. 3 days; 简洁处理逾期
        A.paymentDeadline = uint64(block.timestamp) + 3 days;

        emit Finalized(auctionId, A.highestBidder, A.highestBid, A.secondBid, clearing);
    }

    /// @notice Winner pays the clearing price and claims the NFT; seller receives funds.
    function payAndClaim() external payable nonReentrant {
        Auction storage A = _requireActiveAuction();
        if (!A.finalized || A.settled == true) revert NotEnded();
        if (A.highestBidder != msg.sender) revert NotWinner();
        if (block.timestamp > A.paymentDeadline) revert PaymentClosed();
        if (msg.value != A.clearingPrice) revert WrongPayment();

        // Effects
        A.settled = true;

        // Interactions
        // 1) Pay seller
        (bool ok, ) = A.seller.call{value: msg.value}("");
        require(ok, "pay seller failed");

        // 2) Transfer NFT to winner
        _safeTransferNFT(A, address(this), msg.sender, A.tokenId);

        emit WinnerPaidAndClaimed(auctionId, msg.sender, msg.value);
    }

    /// @notice If winner未在截止前付款，卖家可取回NFT，标记本轮结束（流拍处理）。
    function sellerReclaimIfUnpaid() external {
        Auction storage A = _requireActiveAuction();
        if (!A.finalized || A.settled) revert NotEnded();
        if (msg.sender != A.seller) revert NotSeller();
        require(block.timestamp > A.paymentDeadline, "still payable window");

        A.settled = true;
        _safeTransferNFT(A, address(this), A.seller, A.tokenId);
        emit SellerReclaimed(auctionId);
    }

    // --------- Internal helpers ---------
    function _requireAuction(uint256 id) internal view returns (Auction storage A) {
        A = _auctions[id];
        if (A.seller == address(0)) revert NoActiveAuction();
    }

    function _requireActiveAuction() internal view returns (Auction storage A) {
        A = _auctions[auctionId];
        if (A.seller == address(0)) revert NoActiveAuction();
    }

    function _safeTransferNFT(Auction storage A, address from, address to, uint256 tokenId) internal {
        // 简单起见使用 transferFrom（题目允许你在 Remix/测试网操作该 ERC-721）
        // 若你想更安全，可在此添加 ownerOf 检查。
        A.nft.transferFrom(from, to, tokenId);
    }

    // --------- Public helpers for frontends ---------
    function getCommitment(uint256 id, address bidder) external view returns (bytes32) {
        Auction storage A = _requireAuction(id);
        return A.commitments[bidder];
    }

    function getCommitTime(uint256 id, address bidder) external view returns (uint64) {
        Auction storage A = _requireAuction(id);
        return A.commitTime[bidder];
    }

    function getRevealedAmount(uint256 id, address bidder) external view returns (uint256) {
        Auction storage A = _requireAuction(id);
        return A.revealedAmount[bidder];
    }
}
