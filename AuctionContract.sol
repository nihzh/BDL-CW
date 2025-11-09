// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Simple Vickrey Auction House (Commit–Reveal for ERC-721 on Sepolia)
/// @notice Implements sealed-bid, second-price auctions with deterministic tie-break (earlier commit wins).
/// @dev Single active auction at a time; after an auction ends, anyone can start a new one.
interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function getApproved(uint256 tokenId) external view returns (address);
}

interface IERC721Receiver {
    function onERC721Received(address,address,uint256,bytes calldata) external returns (bytes4);
}

contract VickreyAuctionHouse {
    // --------- Errors ---------
    error NoActiveAuction();
    error AuctionActive();
    error NotSeller();
    error NotInCommitPhase();
    error SellerCannotBid();
    error InvalidCommitment();
    error ExactDepositRequired();
    error NoEthAllowed();
    error NotInRevealPhase();
    error RevealAlreadyDone();
    error InvalidRevealedPrice();
    error NotFinalizable();
    error NotWinner();
    error WrongPayment();
    error PaymentClosed();
    error NotEnded();
    error NoClaimable();
    error NoDeposit();
    error WithdrawFailed();
    error NFTNotEscrowed();

    // --------- Restriction Constants ---------
    uint256 public constant MAX_DURATION = 2592000;  // 30 days
    uint256 public constant MAX_PRICE = 1e27; // 1_000_000_000 ETH
    // uint256 public constant MAX_DEPOSIT_PRICE = 0.01 ether; // 0.01 ETH

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

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // --------- Auction Storage ---------
    struct Auction {
        // Item
        // IERC721 nft;
        uint256 tokenId;

        // Roles
        address seller;

        // Pricing
        uint256 reservePrice;
        uint256 depositPrice;

        // Phases (unix seconds)
        uint64 startStamp; // inclusive
        uint64 commitEnd; // exclusive
        uint64 revealEnd; // exclusive
        uint64 settleDuration; // exclusive
        uint64 settleDeadline; // exclusive, after finalize; winner must pay before this

        // Winner settlement
        address highestBidder;
        uint256 highestBid; // value revealed (>= reserve)
        uint256 secondBid;  // second-highest valid revealed value
        uint256 clearingPrice; // amount which the winner to be paid
        bool finalized; // result computed
        bool settled;   // NFT trasferred

        // For deterministic tie-break (earlier commit wins)
        // and to track per-bidder status
        mapping(address => bytes32) commitments;     // bidder => commitment hash
        mapping(address => uint64)  commitSeq;      // bidder => first commit timestamp
        mapping(address => uint256) depositAmount;  // bidder => deposits in commit phase
        mapping(address => uint256) revealedAmount;  // bidder => revealed valid amount

        uint64 commitSeqCounter;
    }

    uint256 public auctionId; // increments per new auction
    mapping(uint256 => Auction) private _auctions;

    // To keep external view functions simple:
    IERC721 public immutable classNFT = IERC721(0x1546Bd67237122754D3F0cB761c139f81388b210); // Sepolia NFT contract from spec
    //IERC721 public immutable classNFT = IERC721(0xd9145CCE52D386f254917e481eB44e9943F39138);

    // --------- Events ---------
    event AuctionStarted(
        uint256 indexed id,
        address indexed seller,
        address indexed nft,
        uint256 tokenId,
        uint256 reservePrice,
        uint256 depositPrice,
        uint256 startStamp,
        uint64 commitEnd,
        uint64 revealEnd,
        uint64 settleDuration
    );
    event BidCommitted(uint256 indexed id, address indexed bidder);
    event BidRevealed(uint256 indexed id, address indexed bidder, uint256 amount);
    event Finalized(uint256 indexed id, address winner, uint256 highest, uint256 second, uint256 clearingPrice);
    event WinnerPaidAndClaimed(uint256 indexed id, address indexed winner, uint256 price);
    event Unsold(uint256 indexed id);
    event SellerReclaimed(uint256 indexed id);
    event WithDrawnDeposit(uint256 indexed id, address indexed bidder);


    // --------- Core Logic ---------
    /// @notice Start a new auction. Seller must own the NFT and approve this contract; NFT is escrowed in.
    /// @param tokenId Token id in the fixed ClassNFT.
    /// @param reservePrice Minimum acceptable price (wei).
    /// @param commitDurationSeconds Commit phase duration in seconds.
    /// @param revealDurationSeconds Reveal phase duration in seconds.
    function startAuction(
        uint256 tokenId,
        uint256 reservePrice,
        uint64 commitDurationSeconds,
        uint64 revealDurationSeconds,
        uint64 settleDurationSeconds
    ) external {
        // Ensure no active auction (last settled or no auction yet)
        if (auctionId != 0) {
            Auction storage prev = _auctions[auctionId];
            require(prev.settled, "previous not ended");
        }

        // Basic checks
        require(commitDurationSeconds > 0 && commitDurationSeconds < MAX_DURATION, "CONFIG: bad commit durations");
        require(revealDurationSeconds > 0 && revealDurationSeconds < MAX_DURATION, "CONFIG: bad reveal durations");
        require(settleDurationSeconds > 0 && settleDurationSeconds < MAX_DURATION, "CONFIG: bad settle durations");
        require(reservePrice >= 0 && reservePrice < MAX_PRICE, "CONFIG: bad reserve price");

        // escrow NFT
        require(classNFT.ownerOf(tokenId) == msg.sender, "not owner");
        // _safeTransferNFT(classNFT, msg.sender, address(this), tokenId);
        _safeTransferNFT(msg.sender, address(this), tokenId);

        // Create auction
        auctionId += 1;
        Auction storage A = _auctions[auctionId];
        // A.nft = classNFT;
        A.tokenId = tokenId;
        A.seller = msg.sender;
        A.reservePrice = reservePrice;
        // deposit = 50% reserve price
        A.depositPrice =  ((reservePrice / 2) < MAX_PRICE ? (reservePrice / 2):MAX_PRICE);

        uint64 nowTs = uint64(block.timestamp);
        A.startStamp = nowTs;
        A.commitEnd = nowTs + commitDurationSeconds;
        A.revealEnd = A.commitEnd + revealDurationSeconds;
        A.settleDuration = settleDurationSeconds;

        emit AuctionStarted(auctionId, msg.sender, address(classNFT), tokenId, reservePrice, A.depositPrice, A.startStamp, A.commitEnd, A.revealEnd, A.settleDuration);
    }

    /// @notice Commit a bid hash during commit phase. One (the last) commit is valid per address
    /// @param commitment keccak256(abi.encodePacked(amount, salt))
    function commitBid(bytes32 commitment) external payable{
        Auction storage A = _requireActiveAuction();
        
        // only commit in commit phase
        if (block.timestamp >= A.commitEnd || block.timestamp < A.startStamp) revert NotInCommitPhase();
        // check commit valid
        if (commitment == bytes32(0)) revert InvalidCommitment();

        // seller can't commit bid
        if (msg.sender == A.seller) revert SellerCannotBid();

        // if first commit, take deposit = reserve price * 0.5
        if (msg.value != A.depositPrice) revert ExactDepositRequired();
        A.depositAmount[msg.sender] += A.depositPrice;

        // if (A.commitments[msg.sender] == bytes32(0)) {
        //     if (msg.value != A.depositPrice) revert ExactDepositRequired();
        //     A.depositAmount[msg.sender] += A.depositPrice;
        // }
        // else {
        //     // refuse deposit in following commits
        //     // require(msg.value == 0, "Deposit only required in first commit");
        //     if(msg.value != 0) revert NoEthAllowed();
        // }

        // seq no. for tied price
        A.commitSeqCounter += 1;
        A.commitSeq[msg.sender] = A.commitSeqCounter;

        // make commitment
        A.commitments[msg.sender] = commitment;

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

        // check commit validation
        bytes32 c = A.commitments[msg.sender];
        if (c == bytes32(0)) revert InvalidCommitment();
        if (keccak256(abi.encodePacked(amount, salt)) != c) revert InvalidCommitment();

        // Record revealed amount (0 treated as invalid anyway)
        A.revealedAmount[msg.sender] = amount;

        // Only bids >= reserve are "valid"
        if (amount < A.reservePrice) revert InvalidRevealedPrice();

        // Update top-2 with deterministic tie-break:
        // 1) higher price wins
        // 2) if equal price, earlier commit wins (smaller seq no.)
        // 3) if equal commit time, earlier reveal wins
        if (amount > A.highestBid) {
            // push down previous highest into second
            if (A.highestBidder != address(0)) {
                A.secondBid = A.highestBid;
            }
            A.highestBid = amount;
            A.highestBidder = msg.sender;
        } else if (amount == A.highestBid && A.commitSeq[msg.sender] < A.commitSeq[A.highestBidder]) {
            // equal highest price, not second price
            A.highestBid = amount;
            A.highestBidder = msg.sender;
        } else if (amount > A.secondBid) {
            // amount < highestBid here
            A.secondBid = amount;
        }
        emit BidRevealed(auctionId, msg.sender, amount);
    }

    /// @notice Finalize result after reveal ends: compute clearing price or mark unsold.
    ///         Sets a payment deadline for the winner to pay and claim.
    function finalize() external {
        Auction storage A = _requireActiveAuction();
        if (block.timestamp < A.revealEnd) revert NotFinalizable();
        require(!A.finalized, "already finalized");

        // CEI
        A.finalized = true;

        // No valid bid >= reserve -> UNSOLD, return NFT to seller
        if (A.highestBidder == address(0)) {
            A.clearingPrice = 0;
            A.settled = true;
            _safeTransferNFT(address(this), A.seller, A.tokenId);
            //_safeTransferNFT(A.nft, address(this), A.seller, A.tokenId);
            emit Unsold(auctionId);
            return;
        }

        // Compute second-price clearing, if no second price
        uint256 dealPrice = (A.secondBid < A.reservePrice) ? A.reservePrice:A.secondBid;

        // determine winner's payment by deposit amount
        if(dealPrice >= A.depositAmount[A.highestBidder]){
            uint256 clearing = dealPrice - A.depositAmount[A.highestBidder];
            A.clearingPrice = clearing;
            // the deposit of winner transfer to the seller, CEI
            uint256 pay = A.depositAmount[A.highestBidder];
            A.depositAmount[A.highestBidder] = 0;
            A.depositAmount[A.seller] = pay;
        }
        // winner's deposit more than deal price
        else if (dealPrice < A.depositAmount[A.highestBidder]){
            uint256 toWithdraw = A.depositAmount[A.highestBidder] - dealPrice;
            A.clearingPrice = 0;
            A.depositAmount[A.highestBidder] = toWithdraw;
            A.depositAmount[A.seller] = dealPrice;
        }

        // Countdown from now
        A.settleDeadline = uint64(block.timestamp) + A.settleDuration;

        emit Finalized(auctionId, A.highestBidder, A.highestBid, A.secondBid, A.clearingPrice);
    }

    /// @notice Winner pays the clearing price and claims the NFT.
    ///     1) there is amount to pay ==> must before the deadline
    ///     2) all amount paid ==> claim anytime (forever reserved)
    function payAndClaim() external payable nonReentrant {
        Auction storage A = _requireActiveAuction();
        if (!A.finalized) revert NotEnded();
        if (A.highestBidder != msg.sender) revert NotWinner();
        if (A.settled) revert NoClaimable();
        if (block.timestamp > A.settleDeadline && A.clearingPrice != 0) revert PaymentClosed();
        if (msg.value != A.clearingPrice) revert WrongPayment();
        
        // Pay seller (if there is amount to pay)
        if (A.clearingPrice != 0){
            A.clearingPrice = 0;
            A.depositAmount[A.seller] += msg.value;
        }

        // Transfer NFT to winner
        A.settled = true;
        _safeTransferNFT(address(this), A.highestBidder, A.tokenId);

        emit WinnerPaidAndClaimed(auctionId, msg.sender, msg.value);
    }

    // claim the previous NFT
    function payAndClaim(uint256 id) external payable nonReentrant {
        Auction storage A = _requireAuction(id);
        if (!A.finalized) revert NotEnded();
        if (A.highestBidder != msg.sender) revert NotWinner();
        if (A.settled) revert NoClaimable();
        // 1) there is amount to pay ==> must before the deadline
        // 2) all amount paid ==> claim anytime (forever reserved)
        if (block.timestamp > A.settleDeadline && A.clearingPrice != 0) revert PaymentClosed();
        if (msg.value != A.clearingPrice) revert WrongPayment();
        
        // Pay seller (if there is amount to pay)
        if (A.clearingPrice != 0){
            A.clearingPrice = 0;
            A.depositAmount[A.seller] += msg.value;
        }

        // Transfer NFT to winner
        A.settled = true;
        _safeTransferNFT(address(this), A.highestBidder, A.tokenId);

        emit WinnerPaidAndClaimed(auctionId, msg.sender, msg.value);
    }

    /// @notice If winner not settle up before settle deadline, auction passed and return the NFT
    function sellerReclaimNFT(uint256 id) external {
        Auction storage A = _requireAuction(id);
        if (!A.finalized) revert NotEnded();
        if (block.timestamp <= A.settleDeadline) revert NotEnded();
        if (msg.sender != A.seller) revert NoClaimable();
        if (A.settled) revert NoClaimable();

        // send NFT to seller
        A.settled = true;
        _safeTransferNFT(address(this), A.seller, A.tokenId);

        // seller get the deposit, CEI
        uint256 amount = A.depositAmount[A.highestBidder];
        A.depositAmount[A.highestBidder] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if(!ok) revert WithdrawFailed();

        emit SellerReclaimed(auctionId);
    }

    function withdrawDeposits() external nonReentrant{
        Auction storage A = _requireActiveAuction();
        if (!A.finalized) revert NotEnded();
        if (A.depositAmount[msg.sender] == 0) revert NoDeposit();

        uint256 amount = A.depositAmount[msg.sender];
        A.depositAmount[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if(!ok)  revert WithdrawFailed();
        
        emit WithDrawnDeposit(auctionId, msg.sender);
    }

    function withdrawDeposits(uint256 id) external nonReentrant{
        Auction storage A = _requireAuction(id);
        if (!A.finalized) revert NotEnded();
        if (A.depositAmount[msg.sender] == 0) revert NoDeposit();

        uint256 amount = A.depositAmount[msg.sender];
        A.depositAmount[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        if(!ok)  revert WithdrawFailed();
        
        emit WithDrawnDeposit(auctionId, msg.sender);
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

    // function _safeTransferNFT(IERC721 nft, address from, address to, uint256 tokenId) internal {
    function _safeTransferNFT(address from, address to, uint256 tokenId) internal {
        require(classNFT.ownerOf(tokenId) == from, "NFT: not owner");
        if (to == address(this)) {
            require(
                classNFT.getApproved(tokenId) == address(this) ||
                classNFT.isApprovedForAll(from, address(this)),
                "NFT: not approved"
            );
        }

        classNFT.safeTransferFrom(from, to, tokenId);
    }

    // --------- Public helpers for frontends ---------
    function getCommitment(uint256 id, address bidder) external view returns (bytes32) {
        Auction storage A = _requireAuction(id);
        return A.commitments[bidder];
    }

    function getCommitSeq(uint256 id, address bidder) external view returns (uint64) {
        Auction storage A = _requireAuction(id);
        return A.commitSeq[bidder];
    }

    function getDepositAmount(uint256 id, address bidder) external view returns (uint256) {
        Auction storage A = _requireAuction(id);
        return A.depositAmount[bidder];
    }

    function getRevealedAmount(uint256 id, address bidder) external view returns (uint256) {
        Auction storage A = _requireAuction(id);
        return A.revealedAmount[bidder];
    }

    function currentPhase(uint256 id) public view returns (string memory) {
        Auction storage A = _requireAuction(id);
        uint256 t = block.timestamp;
        if (t < A.commitEnd) return "COMMIT";
        if (t < A.revealEnd) return "REVEAL";
        if (!A.finalized) return "FINALIZE_PENDING";
        if (A.finalized && !A.settled && A.highestBidder != address(0) && t <= A.settleDeadline) return "AWAIT_PAYMENT";
        return "ENDED";
    }

    function getWinnerInfo(uint256 id) external view returns (address winner, uint256 price, uint64 payDeadline) {
        Auction storage A = _requireAuction(id);
        // uint256 amount = A.clearingPrice > A.depositAmount[A.highestBidder] ? (A.clearingPrice - A.depositAmount[A.highestBidder]):0;
        return (A.highestBidder, A.clearingPrice, A.settleDeadline);
    }

    // return set stage timestamps
    function getTimes(uint256 id) external view returns (uint64 startStamp, uint64 commitEnd, uint64 revealEnd, uint64 settleDeadline) {
        Auction storage A = _requireAuction(id);
        return (A.startStamp, A.commitEnd, A.revealEnd, A.settleDeadline);
    }

}
