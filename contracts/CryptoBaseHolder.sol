
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { PausableUpgradeable } from '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';
import { ReentrancyGuardUpgradeable } from '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import { OwnableUpgradeable } from '@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol';

interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] memory path)
    external
    view
    returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);
}

contract CryptoBaseHolder is ReentrancyGuardUpgradeable, OwnableUpgradeable
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    struct TradeFeeInfo{
        uint256 inAmount;
        uint256 outAmount;
    }
    mapping(address=>TradeFeeInfo) tradeFeeMap;

    struct CreateFeeInfo{
        uint256 inAmount;
        uint256 outAmount;
    }

    event ClaimedTokens(address token, address owner, uint256 balance);
    mapping(address=>CreateFeeInfo) createFeeMap;

    uint256 exchangeHGTAmount = 0;

    address private constant BURN_ADDRESS = address(1);
    address private constant ETH_ADDRESS = 0x000000000000000000000000000000000000bEEF;

    address public hgt;
    address public xhgt;

    //address of the uniswap v2 router
    address private dex_router_contract = address(0x0);
    address private wrapped_ether = address(0x0);

    // mapping for maker
    //    address public maker = address(0x0);
    mapping(address => bool) public makers;
    address public operator = address(0x0);

    // add Maker
    event MakerAdded(address indexed account);
    event CreateFeeAdded(address token, uint256 amount, uint256 total);
    event TradeFeeAdded(address token, uint256 amount, uint256 total);
    event TokenBurned(address token, uint256 amount, uint256 balance);
    event HGTBuyBack(address token, uint256 amount, uint256 hgtAmount, uint256 tradeInAmount, uint256 tradeOutAmount);
    event HGTExchanged(uint256 amount, uint256 total);
    event SwapRouterChanged(address router, address weth);

    modifier onlyMaker() {
        require(makers[msg.sender] == true, "Only maker can call");
        _;
    }

    modifier onlyOperator(){
        require (msg.sender == operator, "Only operator can call");
        _;
    }

    enum Operations { SET_OPERATOR, SET_SWAPROUTER, CLAIM_ASSETS, CLAIM_TOKENS, SET_MAKER}
    uint256 private constant _TIMELOCK = 1 days;
    mapping(Operations => uint256) public timelock;

    modifier notLocked(Operations _fn) {
        require(timelock[_fn] != 0 && timelock[_fn] >= block.timestamp, "Operation is timelocked");
        _;
    }

    //unlock timelock
    function unlockOperation(Operations _fn) public onlyOwner {
        timelock[_fn] = block.timestamp + _TIMELOCK;
    }

    //lock timelock
    function lockOperation(Operations _fn) public onlyOwner {
        timelock[_fn] = 0;
    }

    function setOperator(address _operator) public onlyOperator notLocked(Operations.SET_OPERATOR){
        require(_operator != owner(), "operator can not be owner");
        operator = _operator;
        timelock[Operations.SET_OPERATOR] = 0;
    }

    function initialize(
        address _hgt, address _xhgt, address _operator
    ) external initializer {
        __ReentrancyGuard_init();
        __Ownable_init();
        hgt = _hgt;
        xhgt = _xhgt;
        require(_operator != owner(), "operator can not be owner");
        operator = _operator;
    }

    function setMaker(address _account, bool _flag) external onlyOperator notLocked(Operations.SET_MAKER) {
        require(isContract(_account) && _account != address(0x0), "address is invalid");

        makers[_account] = _flag;
        emit MakerAdded(_account);
        timelock[Operations.SET_MAKER] = 0;
    }

    function isContract(address _addr) private view returns  (bool){
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }

    function addCreateFee(address _token, uint256 _amount) public payable onlyMaker{
        CreateFeeInfo storage createFeeInfo = createFeeMap[_token];
        createFeeInfo.inAmount = createFeeInfo.inAmount.add(_amount);
        emit CreateFeeAdded(_token, _amount, createFeeInfo.inAmount);
    }

    function addTradeFee(address _token, uint256 _amount) public payable onlyMaker{
        TradeFeeInfo storage tradeFeeInfo = tradeFeeMap[_token];
        tradeFeeInfo.inAmount = tradeFeeInfo.inAmount.add(_amount);
        emit TradeFeeAdded(_token, _amount, tradeFeeInfo.inAmount);
    }

    function setSwapRouter(address _router, address _wether) external onlyOperator notLocked(Operations.SET_SWAPROUTER)
    {
        dex_router_contract = _router;
        wrapped_ether = _wether;
        timelock[Operations.SET_SWAPROUTER] = 0;
        emit SwapRouterChanged(_router, _wether);
    }

    //销毁创作税XHGT
    function burnXHGT() external onlyOperator{
        CreateFeeInfo storage createFeeInfo = createFeeMap[xhgt];

        require(createFeeInfo.inAmount > createFeeInfo.outAmount, "CryptoBase: counter error or no need to burn");

        uint256 amount = createFeeInfo.inAmount.sub(createFeeInfo.outAmount);
        IERC20 erc20token = IERC20(xhgt);

        uint256 balance = erc20token.balanceOf(address(this));
        require(balance >= amount, "CryptoBase: Not enough XHGT to burn"); //合约要销毁的XHGT不足

        createFeeInfo.outAmount = createFeeInfo.inAmount;
        erc20token.safeTransfer(BURN_ADDRESS, amount);
        emit TokenBurned(xhgt, amount, balance);
    }
    //销毁HGT
    function burnHGT() external onlyOperator{
        IERC20 erc20token = IERC20(hgt);

        uint256 balance = erc20token.balanceOf(address(this));
        require(balance >= exchangeHGTAmount, "CryptoBase: Not enough HGT to burn"); //合约要销毁HGT不足
        erc20token.safeTransfer(BURN_ADDRESS, exchangeHGTAmount);
        emit TokenBurned(hgt, exchangeHGTAmount, balance);
        exchangeHGTAmount = 0;
    }

    //HGT兑换XHGT
    function exchangeHGTtoXHGT(uint256 amount) public  nonReentrant {
        require(amount > 0, "CryptoBase: amount is invalid");

        IERC20 erc20HGT = IERC20(hgt);
        uint256 balance = erc20HGT.balanceOf(msg.sender);
        require(balance >= amount, "CryptoBase: Not enough HGT"); //用户账户HGT不足

        IERC20 erc20XHGT = IERC20(xhgt);
        uint256 xbalance = erc20XHGT.balanceOf(address(this));
        require(xbalance >= amount, "CryptoBase: Not enough XHGT"); //合约账户XHGT不足

        erc20HGT.safeTransferFrom(msg.sender, address(this), amount);
        exchangeHGTAmount = exchangeHGTAmount.add(amount);//增加计数

        erc20XHGT.safeTransfer(msg.sender, amount); //从平台转相同数量的XHGT给用户
        emit HGTExchanged(amount, exchangeHGTAmount);
    }

    //提取主流资产
    function claimAssets(address token) external onlyOperator notLocked(Operations.CLAIM_ASSETS)  nonReentrant{
        //查看相应token的余额
        TradeFeeInfo storage tradeFeeInfo = tradeFeeMap[token];
        uint256 tradeFeeAmount = tradeFeeInfo.inAmount.sub(tradeFeeInfo.outAmount);//交易税总余额

        //50%回购HGT
        uint256 buyBackAmount = tradeFeeAmount.div(2);
        uint256 withdrawAmount = tradeFeeAmount.sub(buyBackAmount);

        uint256 outMin;
        address[] memory path;
        //另外50%提取到主流资产
        if(token == address(ETH_ADDRESS))
        {
            path = new address[](2);
            path[0] = wrapped_ether;
            path[1] = hgt;
            outMin = _getAmountOutMin(wrapped_ether, buyBackAmount);//计算可以兑换多少token
            IUniswapV2Router(dex_router_contract).swapExactETHForTokens(outMin, path, address(this), block.timestamp + 1200);
            payable(msg.sender).transfer(withdrawAmount);
        }
        else {

            path = new address[](2);
            path[0] = token;
            path[1] = hgt;
            outMin = _getAmountOutMin(token, buyBackAmount);//计算可以兑换多少token
            IUniswapV2Router(dex_router_contract).swapExactTokensForTokens(buyBackAmount, outMin, path, address(this), block.timestamp+1200);

            IERC20 erc20 = IERC20(token);
            erc20.safeTransfer(msg.sender, withdrawAmount);
        }

        //销毁HGT
        IERC20 erc20HGT = IERC20(hgt);
        erc20HGT.safeTransfer(BURN_ADDRESS, outMin);
        timelock[Operations.CLAIM_ASSETS] = 0;
        emit HGTBuyBack(token, buyBackAmount, outMin, tradeFeeInfo.inAmount, tradeFeeInfo.outAmount);
        tradeFeeInfo.outAmount = tradeFeeInfo.inAmount;
    }

    function claimTokens(address _token, uint256 _amount) public onlyOperator notLocked(Operations.CLAIM_TOKENS)  nonReentrant{

        //Make sure their are enough fund to buy back HGT
        TradeFeeInfo memory tradeFeeInfo = tradeFeeMap[_token];
        uint256 tradeFeeAmount = tradeFeeInfo.inAmount.sub(tradeFeeInfo.outAmount);//交易税总余额

        if (_token == address(ETH_ADDRESS)) {
            uint256 ethbalance = address(this).balance;
            require(ethbalance >= _amount.add(tradeFeeAmount), "Not enough Fund");
            payable(msg.sender).transfer(_amount);
            emit ClaimedTokens(_token, msg.sender, _amount);
            return;
        }
        //Make sure the correct token amount to withdraw
        uint256 extraAmount = 0;
        if (_token == hgt){
            extraAmount = exchangeHGTAmount;
        } else if(_token == xhgt){
            CreateFeeInfo memory createFeeInfo = createFeeMap[xhgt];
            extraAmount = createFeeInfo.inAmount.sub(createFeeInfo.outAmount).add(tradeFeeAmount);
        } else{
            extraAmount = tradeFeeAmount;
        }
        IERC20 erc20token = IERC20(_token);
        uint256 balance = erc20token.balanceOf(address(this));
        require(balance >= _amount.add(extraAmount), "Not enough Fund");
        erc20token.safeTransfer(msg.sender, _amount);
        timelock[Operations.CLAIM_TOKENS] = 0;
        emit ClaimedTokens(_token, msg.sender, _amount);
    }

    function _getAmountOutMin(address _tokenIn, uint256 _amountIn) private view returns (uint256) {
        address[] memory path;
        path = new address[](2);
        path[0] = _tokenIn;
        path[1] = hgt;

        uint256[] memory amountOutMins = IUniswapV2Router(dex_router_contract).getAmountsOut(_amountIn, path);
        return amountOutMins[path.length -1];
    }
    receive() external payable {}

    fallback() external payable {}
}
