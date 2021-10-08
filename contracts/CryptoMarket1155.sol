pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { ReentrancyGuardUpgradeable } from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import { OwnableUpgradeable } from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

interface ICryptoHolder {
    function addTradeFee(address _token, uint256 _amount) external payable;
}

// 艺术品交易合约
contract CryptoMarket1155 is ReentrancyGuardUpgradeable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    ICryptoHolder public holder;

    // 交易费用比例 2.5%
    uint256 public tradeFeeRate = 250;

    address constant etherAddr = 0x000000000000000000000000000000000000bEEF;

    struct Art {
        uint256 price; // 价格
        uint256 count;
        address payToken; // 支付币种
        bool isOnSale; // 是否售卖中
    }

    mapping(address => mapping(address => mapping(uint256 => Art))) public artList;
    mapping(address => bool) public payTokens;
    mapping(address => bool) public blackList;

    address private operator;
    enum Operations { SET_OPERATOR, SET_FEE, SET_BLACK_LIST, SET_PAY_TOKEN }
    uint256 private constant _TIMELOCK = 1 days;
    mapping(Operations => uint256) public timelock;

    event PutOnSale(IERC1155 artNFT, uint256 tokenId, uint256 count, address payToken, uint256 price);
    event PutOffSale(IERC1155 artNFT, uint256 tokenId);
    event BuyArt(address seller, IERC1155 artNFT, uint256 tokenId, uint256 count, address payToken, uint256 price);
    event Donate(address to, IERC1155 artNFT, uint256 tokenId, uint256 count, address payToken, uint256 price);
    event Burn(IERC1155 artNFT, uint256 tokenId, uint256 count);

    modifier notLocked(Operations _fn) {
        require(timelock[_fn] != 0 && timelock[_fn] >= block.timestamp, "Operation is timelocked");
        _;
    }

    modifier onlyOperator(){
        require (msg.sender == operator, "Only operator can call");
        _;
    }

    function initialize(ICryptoHolder _holder, address _operator) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init();
        holder = _holder;
        require(_operator != owner(), "operator can not be owner");
        operator = _operator;
    }

    function unlockOperation(Operations _fn) public onlyOwner {
        timelock[_fn] = block.timestamp + _TIMELOCK;
    }

    function lockOperation(Operations _fn) public onlyOwner {
        timelock[_fn] = 0;
    }

    function setOperator(address _operator) public onlyOperator notLocked(Operations.SET_OPERATOR){
        require(_operator != owner(), "operator can not be owner");
        operator = _operator;
        timelock[Operations.SET_OPERATOR] = 0;
    }

    function setFee(uint256 _tradeFeeRate) public onlyOperator notLocked(Operations.SET_FEE) {
        tradeFeeRate = _tradeFeeRate;
        timelock[Operations.SET_FEE] = 0;
    }

    function setPayToken(address _payToken, bool _flag) external onlyOperator notLocked(Operations.SET_PAY_TOKEN) {
        payTokens[_payToken] = _flag;
        timelock[Operations.SET_PAY_TOKEN] = 0;
    }

    function setBlackList(address _nftToken, bool _flag) external onlyOperator notLocked(Operations.SET_BLACK_LIST) {
        blackList[_nftToken] = _flag;
        timelock[Operations.SET_BLACK_LIST] = 0;
    }

    function putOnSale(IERC1155 _nftToken, uint256 _tokenId, address _payToken, uint256 _price, uint256 _count) external {
        // 只有持有者可以挂单
        require(blackList[address(_nftToken)] == false, 'Not supported');
        require(_nftToken.balanceOf(msg.sender, _tokenId) >= _count, 'Not enough fund');
        require(_nftToken.isApprovedForAll(msg.sender, address(this)), 'Not approved');
        require(_price > 0, 'Price can not be zero');
        require(payTokens[_payToken], 'Not supported pay token');

        Art storage _art = artList[address(_nftToken)][msg.sender][_tokenId];
        _art.count = _count;
        _art.price = _price;
        _art.payToken = _payToken;
        _art.isOnSale = true;

        emit PutOnSale(_nftToken, _tokenId, _count, _payToken, _price);
    }

    function putOffSale(IERC1155 _nftToken, uint256 _tokenId) external {
//        require(blackList[address(_nftToken)] == false, 'Not supported');
        Art storage _art = artList[address(_nftToken)][msg.sender][_tokenId];
        require(_art.isOnSale == true, 'Not on sale');

        _art.isOnSale = false;

        emit PutOffSale(_nftToken, _tokenId);
    }

    function buyArt(IERC1155 _nftToken, address _seller, uint256 _tokenId, uint256 _count, address _payToken, uint256 _price) external payable {
        require(blackList[address(_nftToken)] == false, 'Not supported');
        Art storage _art = artList[address(_nftToken)][_seller][_tokenId];
        require(_art.count >= _count, 'Not enough art for sale');
        require(_art.isOnSale == true, 'Not on sale');
        require(_art.payToken == _payToken && _art.price == _price, 'Price changed');
        require(_seller != msg.sender, 'Owner can not buy');

        _chargeFee(_art, _seller, _count, true);

        // 转移NFT
        _nftToken.safeTransferFrom(_seller, msg.sender, _tokenId, _count, '');

        // 艺术品卖完后自动下架
        _art.count = _art.count - _count;
        if (_art.count == 0) {
            _art.isOnSale = false;
        }

        emit BuyArt(_seller, _nftToken, _tokenId, _count, _payToken, _price);
    }

    function _chargeFee(Art memory _art, address _seller, uint256 _count, bool _chargeTrade) private {

        if (_art.payToken == address(0)) { // 未上架
            return;
        }

        // 计算费用
        uint256 _pay = _art.price.mul(_count);
        uint256 _tradeFee = _art.price.mul(_count).mul(tradeFeeRate).div(10000);
        uint256 _income = _chargeTrade ? _pay.sub(_tradeFee) : 0;

        // 转账
        if (_art.payToken == etherAddr) { // 主币作为手续费
            // 平台手续费
            holder.addTradeFee{value:_tradeFee}(etherAddr, _tradeFee);
            // 卖家获得剩余价值
            if (_chargeTrade) {
                payable(_seller).transfer(_income);
            }
        } else {
            require(msg.value == 0, 'No fee needed');
            // ERC20交易
            IERC20 _payTokenErc20 = IERC20(_art.payToken);
            // 平台手续费
            _payTokenErc20.safeTransfer(address(holder), _tradeFee);
            holder.addTradeFee(_art.payToken, _tradeFee);
            // 卖家收入
            if (_chargeTrade) {
                _payTokenErc20.safeTransfer(_seller, _income);
            }
        }
    }

    function burn(IERC1155 _nftToken, uint256 _tokenId, uint256 _count) external {
        // 销毁token
        _nftToken.safeTransferFrom(msg.sender, address(1), _tokenId, _count, '');
        // 删除挂单信息
        delete artList[address(_nftToken)][msg.sender][_tokenId];

        emit Burn(_nftToken, _tokenId, _count);
    }

    function donate(address _to, IERC1155 _nftToken, uint256 _tokenId, uint256 _count, address _payToken, uint256 _price) payable external {
        Art storage _art = artList[address(_nftToken)][msg.sender][_tokenId];
        require(_art.payToken == _payToken && _art.price == _price, 'Price changed');
        // 收取费用
        _chargeFee(_art, msg.sender, _count, false);
        // 转账
        _nftToken.safeTransferFrom(msg.sender, _to, _tokenId, _count, '');
        // 余额不够则下架
        if (_nftToken.balanceOf(msg.sender, _tokenId) < _art.count) {
            _art.isOnSale = false;
        }
        emit Donate(_to, _nftToken, _tokenId, _count, _payToken, _price);
    }
}
