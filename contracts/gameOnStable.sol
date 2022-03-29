// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract psDFIRE is ERC20, ERC20Burnable, Pausable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bool public locked = false;

    constructor() ERC20("psDFIRE", "psDFIRE") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    function lock() public onlyRole(MINTER_ROLE) {
        locked = true;
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        if (!locked) {
            _mint(to, amount);
        }
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(from, to, amount);
    }
}

contract DeFIREGameOn is Ownable, ReentrancyGuard {
    using SafeERC20 for ERC20;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // -------------------------------------------------------------------------------

    // treasury ops multisig
    address public immutable multisigAddress;

    address public immutable psDFIREAddress;

    // // reputation token
    address public immutable xFLAREAddress;

    // invest token address (stable?18)
    address public immutable stableTokenAddress;

    IERC20 public stableToken;
    IERC20 public flareToken;
    psDFIRE public psDFIREToken;

    // -------------------------------------------------------------------------------

    struct InvestorStats {
        uint256 depositedNative;
        uint256 depositedUSD;
        uint256 psDFIRE;
        string referral;
    }

    mapping(address => InvestorStats) public investorMatrix;

    mapping(address => mapping(uint256 => uint256)) public phasedPledgeStable;

    // ------------------------------------------------------------------------------- time

    uint256 public createTime;

    uint256 public sessionStartTime;
    uint256 public sessionEndTime;

    uint256 public phaseOneEndTime;
    uint256 public phaseTwoEndTime;
    uint256 public phaseThreeEndTime;

    // -------------------------------------------------------------------------------

    uint256 public minimumStable = 100 * 10 ** 6;
    uint256 public phaseTime = 100;

    // ------------------------------------------------------------------------------- events

    event DepositedStable(
        uint256 indexed phase,
        address indexed wallet,
        uint256 amount
    );

    // -------------------------------------------------------------------------------

    constructor(
        address _stableAddress,
        address _xFLAREAddress,
        address _psDFIREAddress,
        address _multisigAddress,
        uint256 _sessionStartTime,
        uint256 _phaseTime,
        uint256 _minimumStable
    ) {
        require(
            _sessionStartTime > _phaseTime,
            "sessionStartTime must be greater than phase time"
        );

        require(_stableAddress != address(0), "Address cannot be 0x");
        require(_xFLAREAddress != address(0), "Address cannot be 0x");
        require(_psDFIREAddress != address(0), "Address cannot be 0x");

        require(_minimumStable > 1 *10**6, "Minimum deposit should be higher than 1");

        minimumStable = _minimumStable * 10 ** 6;
 
        stableToken = ERC20(_stableAddress);
        flareToken = ERC20(_xFLAREAddress);
        psDFIREToken = psDFIRE(_psDFIREAddress);

        stableTokenAddress = _stableAddress;
        psDFIREAddress = _psDFIREAddress;

        multisigAddress = _multisigAddress;
        xFLAREAddress = _xFLAREAddress;

        phaseTime = _phaseTime;

        sessionStartTime = _sessionStartTime;
        phaseOneEndTime = _sessionStartTime + (phaseTime * 1);
        phaseTwoEndTime = _sessionStartTime + (phaseTime * 2);
        phaseThreeEndTime = _sessionStartTime + (phaseTime * 3);
        sessionEndTime = phaseThreeEndTime;

        createTime = block.timestamp;
    }

    // ----------------------------------------------------------------------------------------

    function seedPhase() public view returns (uint256) {
        if (block.timestamp < sessionStartTime) {
            return 0;
        }
        if (block.timestamp < phaseOneEndTime) {
            return 1;
        }
        if (block.timestamp < phaseTwoEndTime) {
            return 2;
        }
        if (block.timestamp < phaseThreeEndTime) {
            return 3;
        }
        return 0;
    }

    function amountDepositedStable() public view onlyOwner returns (uint256) {
        return stableToken.balanceOf(address(this));
    }

    // -------------------------------------------------------------------------------

    function myEligibility() public view returns (bool) {
        if (seedPhase() < 3 && flareToken.balanceOf(msg.sender) > 2 ether) {
            return true;
        }
        if (seedPhase() > 2) {
            return true;
        }
        return false;
    }

    function myFLARE() public view returns (uint256) {
        return flareToken.balanceOf(msg.sender);
    }

    function myPSDFIRE() public view returns (uint256) {
        return investorMatrix[msg.sender].psDFIRE;
    }

    // -------------------------------------------------------------------------------

    function depositStable(uint256 _amount, string memory _referral)
        external
        nonReentrant
    {
        require(
            msg.sender != multisigAddress,
            "MultiSig address cannot deposit"
        );
        require(
            stableToken.balanceOf(msg.sender) >= _amount,
            "Not enough USDC to deposit"
        );
        require(_amount >= minimumStable, "Less than minimum deposit");
        require(seedPhase() > 0, "Seed Round Closed");

        if (seedPhase() < 3) {
            require(
                flareToken.balanceOf(msg.sender) >= 3 ether,
                "Not enough FLARE to deposit"
            );
        }

        InvestorStats storage investor = investorMatrix[msg.sender];

        stableToken.safeTransferFrom(msg.sender, address(this), _amount);

        psDFIREToken.mint(msg.sender, _amount);

        investor.depositedUSD += _amount;
        investor.psDFIRE += _amount;
        investor.referral = _referral;

        phasedPledgeStable[msg.sender][seedPhase()] += _amount;

        emit DepositedStable(seedPhase(), msg.sender, _amount);
    }

    // ----------------------------------------------------------------------------------------

    function withdrawStablesToTreasury() public onlyOwner {
        require(seedPhase() == 0, "Seed Round Not Closed Yet");
        stableToken.safeTransfer(
            multisigAddress,
            stableToken.balanceOf(address(this))
        );
        psDFIREToken.lock();
    }

    function withdrawNativeToTreasury() public payable onlyOwner {
        require(seedPhase() == 0, "Seed Round Not Closed Yet");
        payable(multisigAddress).transfer(address(this).balance);
    }

    function withdrawUnclaimedToTreasury(IERC20 _token) public onlyOwner {
        require(seedPhase() == 0, "Seed Round Not Closed Yet");
        _token.safeTransfer(multisigAddress, _token.balanceOf(address(this)));
    }
}
