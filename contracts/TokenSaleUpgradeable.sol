// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/BadgerGuestlistApi.sol";

/**
 * @notice Sells a token at a predetermined price to whitelisted buyers.
 * TODO: Better revert strings
 */
contract TokenSaleUpgradeable is OwnableUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for ERC20Upgradeable;

    /// token to give out (CTDL)
    ERC20Upgradeable public tokenOut;
    /// token to take in WBTC / bibbtc LP / CVX / bveCVX
    ERC20Upgradeable public tokenIn;
    /// time when tokens can be first purchased
    uint64 public saleStart;
    /// duration of the token sale, cannot purchase afterwards
    uint64 public saleDuration;
    /// address receiving the proceeds of the sale - will be citadel multisig
    address public saleRecipient;
    /// whether the sale has been finalized
    bool public finalized;

    /// tokenIn per tokenOut price
    /// eg. 1 WBTC (8 decimals) = 40,000 CTDL ==> price = 10^8 / 40,000
    uint256 public tokenOutPrice;

    /// Amounts bought by accounts
    mapping(address => uint256) public boughtAmounts;
    /// Whether an account has claimed tokens
    /// NOTE: can reset boughtAmounts after a claim to optimize gas
    ///       but we need to persist boughtAmounts
    mapping(address => bool) public hasClaimed;

    /// Amount of `tokenIn` taken in
    uint256 public totalTokenIn;
    /// Amount of `tokenOut` sold
    uint256 public totalTokenOutBought;
    /// Amount of `tokenOut` claimed
    uint256 public totalTokenOutClaimed;

    /// Max tokenIn that can be taken by the contract (defines the cap for tokenOut sold)
    uint256 public tokenInLimit;

    /// Whitelist
    BadgerGuestListAPI public guestlist;

    /// Amount vote for each DAO
    mapping(uint8 => uint256) public daoCommitments;
    mapping(address => uint8) public daoVotedFor;

    /// ==================
    /// ===== Events =====
    /// ==================

    event Sale(
        address indexed buyer,
        uint8 indexed daoId,
        uint256 amountIn,
        uint256 amountOut
    );
    event Claim(address indexed claimer, uint256 amount);
    event Finalized();

    event SaleStartUpdated(uint64 saleStart);
    event SaleDurationUpdated(uint64 saleDuration);
    event TokenOutPriceUpdated(uint256 tokenOutPrice);
    event SaleRecipientUpdated(address indexed recipient);
    event GuestlistUpdated(address indexed guestlist);
    event TokenInLimitUpdated(uint256 tokenInLimit);

    event Sweeped(address indexed token, uint256 amount);

    /// =======================
    /// ===== Initializer =====
    /// =======================

    /**
     * @notice Initializer.
     * @param _tokenOut The token this contract will return in a trade
     * @param _tokenIn The token this contract will receive in a trade
     * @param _saleStart The time when tokens can be first purchased
     * @param _saleDuration The duration of the token sale
     * @param _tokenOutPrice The tokenIn per tokenOut price
     * @param _saleRecipient The address receiving the proceeds of the sale - will be citadel multisig
     * @param _guestlist Address that will manage auction approvals
     * @param _tokenInLimit The max tokenIn that the contract can take
     */
    function initialize(
        address _tokenOut,
        address _tokenIn,
        uint64 _saleStart,
        uint64 _saleDuration,
        uint256 _tokenOutPrice,
        address _saleRecipient,
        address _guestlist,
        uint256 _tokenInLimit
    ) external initializer {
        require(
            _saleStart >= block.timestamp,
            "TokenSale: start date may not be in the past"
        );
        require(
            _saleDuration > 0,
            "TokenSale: the sale duration must not be zero"
        );
        require(_tokenOutPrice > 0, "TokenSale: the price must not be zero");
        require(
            _saleRecipient != address(0),
            "TokenSale: sale recipient should not be zero"
        );

        __Ownable_init();
        __Pausable_init();

        tokenOut = ERC20Upgradeable(_tokenOut);
        tokenIn = ERC20Upgradeable(_tokenIn);
        saleStart = _saleStart;
        saleDuration = _saleDuration;
        tokenOutPrice = _tokenOutPrice;
        saleRecipient = _saleRecipient;
        guestlist = BadgerGuestListAPI(_guestlist);
        tokenInLimit = _tokenInLimit;
    }

    /// ==========================
    /// ===== Public actions =====
    /// ==========================

    /**
     * @notice Exchange `_tokenInAmount` of `tokenIn` for `tokenOut`
     * @param _tokenInAmount Amount of `tokenIn` to give
     * @param _daoId ID of DAO to vote for
     * @param _proof Merkle proof for the guestlist. Use `new bytes32[](0)` if there's no guestlist
     * @return tokenOutAmount_ Amount of `tokenOut` bought
     */
    function buy(
        uint256 _tokenInAmount,
        uint8 _daoId,
        bytes32[] calldata _proof
    ) external whenNotPaused returns (uint256 tokenOutAmount_) {
        require(saleStart <= block.timestamp, "TokenSale: not started");
        require(
            block.timestamp < saleStart + saleDuration,
            "TokenSale: already ended"
        );
        require(_tokenInAmount > 0, "_tokenInAmount should be > 0");
        require(
            totalTokenIn + _tokenInAmount <= tokenInLimit,
            "total amount exceeded"
        );

        if (address(guestlist) != address(0)) {
            require(guestlist.authorized(msg.sender, _proof), "not authorized");
        }

        uint256 boughtAmountTillNow = boughtAmounts[msg.sender];

        if (boughtAmountTillNow > 0) {
            require(
                _daoId == daoVotedFor[msg.sender],
                "can't vote for multiple daos"
            );
        } else {
            daoVotedFor[msg.sender] = _daoId;
        }

        tokenOutAmount_ = getAmountOut(_tokenInAmount);

        boughtAmounts[msg.sender] = boughtAmountTillNow + tokenOutAmount_;
        daoCommitments[_daoId] += tokenOutAmount_;

        totalTokenIn += _tokenInAmount;
        totalTokenOutBought += tokenOutAmount_;

        tokenIn.safeTransferFrom(msg.sender, saleRecipient, _tokenInAmount);

        emit Sale(msg.sender, _daoId, _tokenInAmount, tokenOutAmount_);
    }

    /**
     * @notice Claim bought tokens after sale has been finalized
     */
    function claim() external whenNotPaused returns (uint256 tokenOutAmount_) {
        require(finalized, "sale not finalized");
        require(!hasClaimed[msg.sender], "already claimed");

        tokenOutAmount_ = boughtAmounts[msg.sender];

        require(tokenOutAmount_ > 0, "nothing to claim");

        hasClaimed[msg.sender] = true;
        totalTokenOutClaimed += tokenOutAmount_;

        tokenOut.safeTransfer(msg.sender, tokenOutAmount_);

        emit Claim(msg.sender, tokenOutAmount_);
    }

    /// =======================
    /// ===== Public view =====
    /// =======================

    /**
     * @notice Get the amount received when exchanging `tokenIn`
     * @param _tokenInAmount Amount of `tokenIn` to exchange
     * @return tokenOutAmount_ Amount of `tokenOut` received
     */
    function getAmountOut(uint256 _tokenInAmount)
        public
        view
        returns (uint256 tokenOutAmount_)
    {
        tokenOutAmount_ =
            (_tokenInAmount * 10**tokenOut.decimals()) /
            tokenOutPrice;
    }

    /**
     * @notice Check how much `tokenIn` can still be taken in
     * @return limitLeft_ Amount of `tokenIn` that can still be exchanged
     */
    function getTokenInLimitLeft() external view returns (uint256 limitLeft_) {
        if (totalTokenIn < tokenInLimit) {
            limitLeft_ = tokenInLimit - totalTokenIn;
        }
    }

    /**
     * @notice Check if the sale has ended
     * @return hasEnded_ True if the sale has ended
     */
    function saleEnded() public view returns (bool hasEnded_) {
        hasEnded_ =
            (block.timestamp >= saleStart + saleDuration) ||
            (totalTokenIn >= tokenInLimit);
    }

    /// ===============================
    /// ===== Permissioned: owner =====
    /// ===============================

    /**
     * @notice Finalize the sale after sale duration. Can only be called by owner
       @dev Ensure contract has enough `tokenOut` before calling
     */
    function finalize() external onlyOwner {
        require(!finalized, "TokenSale: already finalized");
        require(saleEnded(), "TokenSale: not finished");
        require(
            tokenOut.balanceOf(address(this)) >= totalTokenOutBought,
            "TokenSale: not enough balance"
        );

        finalized = true;

        emit Finalized();
    }

    /**
     * @notice Update the sale start time. Can only be called by owner
     * @param _saleStart New start time
     */
    function setSaleStart(uint64 _saleStart) external onlyOwner {
        require(
            _saleStart >= block.timestamp,
            "TokenSale: start date may not be in the past"
        );
        require(!finalized, "TokenSale: already finalized");

        saleStart = _saleStart;

        emit SaleStartUpdated(_saleStart);
    }

    /**
     * @notice Update sale duration. Can only be called by owner
     * @param _saleDuration New duration
     */
    function setSaleDuration(uint64 _saleDuration) external onlyOwner {
        require(
            _saleDuration > 0,
            "TokenSale: the sale duration must not be zero"
        );
        require(!finalized, "TokenSale: already finalized");

        saleDuration = _saleDuration;

        emit SaleDurationUpdated(_saleDuration);
    }

    /**
     * @notice Modify the tokenOut price in. Can only be called by owner
     * @param _tokenOutPrice New tokenOut price
     */
    function setTokenOutPrice(uint256 _tokenOutPrice) external onlyOwner {
        require(_tokenOutPrice > 0, "TokenSale: the price must not be zero");

        tokenOutPrice = _tokenOutPrice;

        emit TokenOutPriceUpdated(_tokenOutPrice);
    }

    /**
     * @notice Update the `tokenIn` receipient address. Can only be called by owner
     * @param _saleRecipient New recipient address
     */
    function setSaleRecipient(address _saleRecipient) external onlyOwner {
        require(
            _saleRecipient != address(0),
            "TokenSale: sale recipient should not be zero"
        );

        saleRecipient = _saleRecipient;

        emit SaleRecipientUpdated(_saleRecipient);
    }

    /**
     * @notice Update the guestlist address. Can only be called by owner
     * @param _guestlist New guestlist address
     */
    function setGuestlist(address _guestlist) external onlyOwner {
        guestlist = BadgerGuestListAPI(_guestlist);

        emit GuestlistUpdated(_guestlist);
    }

    /**
     * @notice Modify the max tokenIn that this contract can take. Can only be called by owner
     * @param _tokenInLimit New max amountIn
     */
    function setTokenInLimit(uint256 _tokenInLimit) external onlyOwner {
        require(!finalized, "TokenSale: already finalized");

        tokenInLimit = _tokenInLimit;

        emit TokenInLimitUpdated(_tokenInLimit);
    }

    /**
     * @notice Transfers out any tokens accidentally sent to the contract. Can only be called by owner
     * @dev The contract transfers all `tokenIn` directly to `saleRecipient` during a sale so it's safe
     *      to sweep `tokenIn`. For `tokenOut`, the function only sweeps the extra amount
     *      (current contract balance - amount left to be claimed)
     * @param _token The token to sweep
     */
    function sweep(address _token) external onlyOwner {
        uint256 amount = ERC20Upgradeable(_token).balanceOf(address(this));

        if (_token == address(tokenOut)) {
            uint256 amountLeftToBeClaimed = totalTokenOutBought -
                totalTokenOutClaimed;
            amount -= amountLeftToBeClaimed;
        }

        require(amount > 0, "nothing to sweep");

        ERC20Upgradeable(_token).safeTransfer(msg.sender, amount);

        emit Sweeped(_token, amount);
    }

    /**
     * @notice Pause the sale. Can only be called by owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the sale. Can only be called by owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
