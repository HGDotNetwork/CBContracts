pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { ReentrancyGuardUpgradeable } from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import { OwnableUpgradeable } from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

interface ICryptoHolder {
    function addTradeFee(address _token, uint256 _amount) external payable;
}

// 艺术品交易合约
contract CryptoMarket is ReentrancyGuardUpgradeable, OwnableUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    ICryptoHolder public holder;

    // 交易费用比例 2.5%
    uint256 public tradeFeeRate = 250;
    // 版税最大值 8%
    uint256 public maxRoyaltyRate = 800;

    address constant etherAddr = 0x000000000000000000000000000000000000bEEF;

    struct Art {
        address payable author; // 作者
        uint256 royaltyRate; // 版税
        uint256 minPrice; // 最低价格
        uint256 price; // 价格
        address payToken; // 支付币种
        bool isOnSale; // 是否售卖中
    }

    mapping(address => mapping(uint256 => Art)) public artList;
    mapping(address => bool) public payTokens;
    mapping(address => bool) public blackList;

    address private operator;
    enum Operations { SET_OPERATOR, SET_FEE, SET_BLACK_LIST, SET_PAY_TOKEN }
    uint256 private constant _TIMELOCK = 1 days;
    mapping(Operations => uint256) public timelock;

    event PutOnSale(IERC721 artNFT, uint256 tokenId, address payToken, uint256 price, uint256 _royaltyRate, uint256 _minPrice);
    event PutOffSale(IERC721 artNFT, uint256 tokenId);
    event BuyArt(IERC721 artNFT, uint256 tokenId, address payToken, uint256 price);
    event Donate(address to, IERC721 artNFT, uint256 tokenId, address payToken, uint256 price);
    event Burn(IERC721 artNFT, uint256 tokenId);

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

    function setFee(uint256 _tradeFeeRate, uint256 _maxRoyaltyRate) public onlyOperator notLocked(Operations.SET_FEE) {
        tradeFeeRate = _tradeFeeRate;
        maxRoyaltyRate = _maxRoyaltyRate;
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

    function putOnSale(IERC721 _nftToken, uint256 _tokenId, address _payToken, uint256 _price, uint256 _royaltyRate, uint256 _minPrice) external {
        // 只有持有者可以挂单
        require(blackList[address(_nftToken)] == false, 'Not supported');
        require(_nftToken.ownerOf(_tokenId) == msg.sender, 'Permission denied');
        require(_nftToken.getApproved(_tokenId) == address(this) || _nftToken.isApprovedForAll(msg.sender, address(this)), 'Not approved');
        require(_price > 0, 'Price can not be zero');
        require(payTokens[_payToken], 'Not supported pay token');

        Art storage _art = artList[address(_nftToken)][_tokenId];
        require(_price >= _art.minPrice, 'Wrong price');
        // 第一个挂单的人设置为作者，并设置版税
        if (_art.author == address(0)) {
            require(_royaltyRate <= maxRoyaltyRate, "Wrong royalty");
            _art.author = payable(msg.sender);
            _art.minPrice = _minPrice;
            _art.royaltyRate = _royaltyRate;
        }
        _art.price = _price;
        _art.payToken = _payToken;
        _art.isOnSale = true;

        emit PutOnSale(_nftToken, _tokenId, _payToken, _price, _royaltyRate, _minPrice);
    }

    function putOffSale(IERC721 _nftToken, uint256 _tokenId) external {
//        require(blackList[address(_nftToken)] == false, 'Not supported');
        Art storage _art = artList[address(_nftToken)][_tokenId];

        // 只有持有者可以撤单
        require(_nftToken.ownerOf(_tokenId) == msg.sender, 'Permission denied');

        _art.isOnSale = false;

        emit PutOffSale(_nftToken, _tokenId);
    }

    function buyArt(IERC721 _nftToken, uint256 _tokenId, address _payToken, uint256 _price) external payable {
        require(blackList[address(_nftToken)] == false, 'Not supported');
        Art storage _art = artList[address(_nftToken)][_tokenId];
        require(_art.isOnSale == true, 'Not on sale');
        require(_art.payToken == _payToken && _art.price == _price, 'Price changed');
        require(_nftToken.ownerOf(_tokenId) != msg.sender, 'Owner can not buy');

        _chargeFee(_art, _nftToken, _tokenId, true);

        // 更换NFT持有者
        _nftToken.safeTransferFrom(_nftToken.ownerOf(_tokenId), msg.sender, _tokenId);

        // 修改艺术品信息
        _art.isOnSale = false;

        emit BuyArt(_nftToken, _tokenId, _payToken, _price);
    }

    function _chargeFee(Art memory _art, IERC721 _nftToken, uint256 _tokenId, bool _chargeTrade) private {

        if (_art.payToken == address(0)) { // 未上架
            return;
        }

        // 计算费用
        uint256 _tradeFee = _art.price.mul(tradeFeeRate).div(10000);
        uint256 _royalty = _art.price.mul(_art.royaltyRate).div(10000);
        uint256 _income = _chargeTrade ? _art.price.sub(_tradeFee).sub(_royalty) : 0;

        // 转账
        if (_art.payToken == etherAddr) { // 主币作为手续费
            // 平台手续费
            holder.addTradeFee{value:_tradeFee}(etherAddr, _tradeFee);
            // 作者收取版费
            payable(_art.author).transfer(_royalty);
            // 卖家获得剩余价值
            if (_chargeTrade) {
                payable(_nftToken.ownerOf(_tokenId)).transfer(_income);
            }
        } else {
            require(msg.value == 0, 'No fee needed');
            // ERC20交易
            IERC20 _payTokenErc20 = IERC20(_art.payToken);
            // 平台手续费
            _payTokenErc20.safeTransfer(address(holder), _tradeFee);
            holder.addTradeFee(_art.payToken, _tradeFee);
            // 版税
            _payTokenErc20.safeTransfer(_art.author, _royalty);
            // 卖家收入
            if (_chargeTrade) {
                _payTokenErc20.safeTransfer(_nftToken.ownerOf(_tokenId), _income);
            }
        }
    }

    function burn(IERC721 _nftToken, uint256 _tokenId) external {
        // 销毁token
        _nftToken.safeTransferFrom(msg.sender, address(1), _tokenId);
        // 删除挂单信息
        delete artList[address(_nftToken)][_tokenId];

        emit Burn(_nftToken, _tokenId);
    }

    function donate(address _to, IERC721 _nftToken, uint256 _tokenId, address _payToken, uint256 _price) payable external {
        Art storage _art = artList[address(_nftToken)][_tokenId];
        require(_art.payToken == _payToken && _art.price == _price, 'Price changed');
        // 收取费用
        _chargeFee(_art, _nftToken, _tokenId, false);
        // 下架
        _art.isOnSale = false;
        // 转账
        _nftToken.safeTransferFrom(msg.sender, _to, _tokenId);
        emit Donate(_to, _nftToken, _tokenId, _payToken, _price);
    }
}
