
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2Router {
    function getAmountsOut(uint256 amountIn, address[] memory path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

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

contract CryptoBaseHolder is Ownable
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

    uint256 exchangeHGTAccount = 0;

    address BURN_ADDRESS = 0x0000000000000000000000000000000000000001;
    address ETH_ADDRESS = 0x000000000000000000000000000000000000bEEF;

    address hgt;
    address xhgt;

    //address of the uniswap v2 router
    address private dex_router_contract = address(0x0);
    address private wrapped_ether = address(0x0);

    // mapping for maker
    address public maker = address(0x0);

    // add Maker
    event MakerAdded(address indexed account);

    modifier onlyMaker() {
        require(msg.sender == maker, "Only maker can call");
        _;
    }
    constructor(address _hgt, address _xhgt) {
        hgt = _hgt;
        xhgt = _xhgt;
    }

    function setMaker(address _account) external onlyOwner {
        require(isContract(_account) && _account != address(0x0), "address is invalid");

        if(maker == address(0x0)) {
            maker = _account;
            emit MakerAdded(_account);
        }
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
    }

    function addTradeFee(address _token, uint256 _amount) public payable onlyMaker{
        TradeFeeInfo storage tradeFeeInfo = tradeFeeMap[_token];
        tradeFeeInfo.inAmount = tradeFeeInfo.inAmount.add(_amount);
    }

    function setSwapRouter(address _router, address _wether) external onlyOwner
    {
        dex_router_contract = _router;
        wrapped_ether = _wether;
    }

    //销毁创作税XHGT
    function burnXHGT() external onlyOwner{
        CreateFeeInfo storage createFeeInfo = createFeeMap[xhgt];

        require(createFeeInfo.inAmount > createFeeInfo.outAmount, "CryptoBase: counter error or no need to burn");
        
        uint256 amount = createFeeInfo.inAmount.sub(createFeeInfo.outAmount);
        IERC20 erc20token = IERC20(xhgt);

        uint256 balance = erc20token.balanceOf(address(this));
        require(balance >= amount, "CryptoBase: Not enough XHGT to burn"); //合约要销毁的XHGT不足

        createFeeInfo.outAmount = createFeeInfo.inAmount;
        erc20token.transfer(BURN_ADDRESS, amount);
    }
    //销毁HGT
    function burnHGT() external onlyOwner{
        IERC20 erc20token = IERC20(hgt);

        uint256 balance = erc20token.balanceOf(address(this));
        require(balance >= exchangeHGTAccount, "CryptoBase: Not enough HGT to burn"); //合约要销毁HGT不足
        erc20token.transfer(BURN_ADDRESS, exchangeHGTAccount);
        exchangeHGTAccount = 0;
    }

    //HGT兑换XHGT
    function exchangeHGTtoXHGT(uint256 amount) public  {
        require(amount > 0, "CryptoBase: amount is invalid");

        IERC20 erc20HGT = IERC20(hgt);
        uint256 balance = erc20HGT.balanceOf(msg.sender);
        require(balance >= amount, "CryptoBase: Not enough HGT"); //用户账户HGT不足
        
        IERC20 erc20XHGT = IERC20(xhgt);
        uint256 xbalance = erc20XHGT.balanceOf(address(this));
        require(xbalance >= amount, "CryptoBase: Not enough XHGT"); //合约账户XHGT不足

         erc20HGT.transferFrom(msg.sender, address(this), amount);
         exchangeHGTAccount = exchangeHGTAccount.add(amount);//增加计数

         erc20XHGT.transfer(msg.sender, amount); //从平台转相同数量的XHGT给用户
    }

    //提取主流资产
    function claimAssets(address token) external onlyOwner {
        //查看相应token的余额
        TradeFeeInfo storage tradeFeeInfo = tradeFeeMap[token];
        uint256 tradeFeeAmount = tradeFeeInfo.inAmount.sub(tradeFeeInfo.outAmount);//交易税总余额

        //50%回购HGT
        tradeFeeAmount = tradeFeeAmount.div(2);

        uint256 outMin;
        address[] memory path;
        //另外50%提取到主流资产
        if(token == address(ETH_ADDRESS))
        {
            path = new address[](2);
            path[0] = wrapped_ether;
            path[1] = hgt;
            outMin = _getAmountOutMin(wrapped_ether, tradeFeeAmount);//计算可以兑换多少token
            IUniswapV2Router(dex_router_contract).swapExactETHForTokens(outMin, path, address(this), block.timestamp + 1200);
            payable(msg.sender).transfer(tradeFeeAmount);
        }
        else {
             
            path = new address[](2);
            path[0] = token;
            path[1] = hgt;
            outMin = _getAmountOutMin(token, tradeFeeAmount);//计算可以兑换多少token
            IUniswapV2Router(dex_router_contract).swapExactTokensForTokens(tradeFeeAmount, outMin, path, address(this), block.timestamp+1200);

            IERC20 erc20 = IERC20(token);
            erc20.transfer(msg.sender, tradeFeeAmount);
        }

        //销毁HGT
        IERC20 erc20HGT = IERC20(hgt);
        erc20HGT.transfer(BURN_ADDRESS, outMin);

        tradeFeeInfo.outAmount = tradeFeeInfo.inAmount;
    }

    function claimTokens(address _token, uint256 _amount) public onlyOwner {
        if (_token == address(0x0)) {
            uint256 ethbalance = address(this).balance;
            require(ethbalance >= _amount, "Not enough Fund");
            payable(owner()).transfer(_amount);
            emit ClaimedTokens(_token, owner(), _amount);
            return;
        }
        IERC20 erc20token = IERC20(_token);
        uint256 balance = erc20token.balanceOf(address(this));
        require(balance >= _amount, "Not enough Fund");
        erc20token.transfer(owner(), _amount);
        emit ClaimedTokens(_token, owner(), _amount);
    }

    function _getAmountOutMin(address _tokenIn, uint256 _amountIn) private view returns (uint256) {
        address[] memory path;
        path = new address[](2);
        path[0] = _tokenIn;
        path[1] = hgt;

        uint256[] memory amountOutMins = IUniswapV2Router(dex_router_contract).getAmountsOut(_amountIn, path);
        return amountOutMins[path.length -1];
    }
}
