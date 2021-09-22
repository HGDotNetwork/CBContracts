pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ICryptoBaseHolder {
    function addTradeFee(address _token, uint256 _amount) external payable;

    function addCreateFee(address _token, uint256 _amount) external payable;
}

interface IArtNFT {
    function create(string memory _tokenURI, uint256 fhash, address creator) external returns (uint256);

    function exchange(uint256 tokenId, address newOwner) external returns (bool);
}

// 艺术品交易市场合约
contract CryptoBase is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    mapping(address=>bool)  public artNFTMap;

    ICryptoBaseHolder cbholder;

    address  public xhgt;

    // 创作艺术品需要的HGT
    uint256  public xhgtCreatePrice = 10*10**18; //这里需要修改
    // 创作艺术品需要的公链Value
    uint256  public ethCreatePrice = 10**15; // 这里需要修改

    //交易费用比例2.5%
    uint256  public swapFeeRate = 250;
    // 版税最大值（万分之N）
    uint256  public royaltyRateMax = 800;

    address public ETH_ADDRESS = 0x000000000000000000000000000000000000bEEF;

    struct MarketItem {
        uint256 nftId; // 物品的合约tokenId
        address payable author; // 作者
        uint256 royaltyRate;// 版税比率：每次交易额的百分比：单位 万分之N

        address payable owner; // 当下该物品的拥有者
        uint256 price; // 出售价格
        address priceToken; // 使用币的类型
        bool isOnSale; // 是否在出售
    }

    mapping(address=>mapping(uint256 => MarketItem)) public idToMarketItem;
    mapping(address=>mapping(uint256 => bool)) private itemHash;
    mapping(address => bool) private _acceptedToken; // 可接受的币种

    event CBMinted(address artNFT, uint256 nftId, string tokenURI, address author,uint256 royaltyRate,uint256 fhash, bool payEth,uint256 price);
    event CBExchanged(address artNFT, uint256 nftId, address oldOwner, address newOwner, address priceToken, uint256 price);
    event CBOnSale(address artNFT, uint256 nftId, address oldPriceToken, uint256 oldPrice, address newPriceToken, uint256 newPrice);
    event CBOffSale(address artNFT, uint256 nftId, address priceToken,uint256 price);

    constructor(address _xhgt, address _cbholder) {
        xhgt = _xhgt;
        cbholder = ICryptoBaseHolder(_cbholder);
    }

    function setArtNFT(address _artNFT) external onlyOwner{
        artNFTMap[_artNFT] = true;
    }
    function setCreatePrice(uint256 _ethValue, uint256 _xhgtValue) external onlyOwner {
        ethCreatePrice = _ethValue;
        xhgtCreatePrice = _xhgtValue;
    }

    function setFeeRate(uint256 _swapFeeRate, uint256 _royaltyRateMax) external onlyOwner {
        require(_swapFeeRate >= 0 && _swapFeeRate < 2000, "CryptoBase: Not valid swapFeeRate");
        require(_royaltyRateMax >= 0 && _royaltyRateMax < 2000, "CryptoBase: Not valid royaltyRateMax");

        swapFeeRate = _swapFeeRate;
        royaltyRateMax = _royaltyRateMax;
    }

    function appendAcceptedToken(address token) external onlyOwner {
        _acceptedToken[token] = true;
    }

    function cancelAcceptedToken(address token) external onlyOwner {
        if (_acceptedToken[token]) {
            _acceptedToken[token] = false;
        }
    }

    // 使用HGT创作艺术品
    function createWithXHGT(
        address _artNFT, string memory tokenURI, uint256 royaltyRate,
        string memory cntHash, string memory fontHash, uint256 align, string memory bgHash
    )
    external returns (uint256) {
        require(artNFTMap[_artNFT], "NFT is not supported");

        uint256 _itemHash = uint256(keccak256(abi.encodePacked(cntHash, fontHash, align, bgHash)));

        require(royaltyRate <= royaltyRateMax, "CryptoBase: Not valid royalty");

        uint256 balance = IERC20(xhgt).balanceOf(msg.sender);
        require(balance >= xhgtCreatePrice, "CryptoBase: XHGT is not enough");

        return createItem(_artNFT, tokenURI, royaltyRate, _itemHash, false);
    }

    // 使用公链币创作艺术品
    function createWithETH(
        address _artNFT, string memory tokenURI, uint256 royaltyRate,
        string memory cntHash, string memory fontHash, uint256 align, string memory bgHash
    )
    public payable returns (uint256) {
        require(artNFTMap[_artNFT], "NFT is not supported");

        uint256 _itemHash = uint256(keccak256(abi.encodePacked(cntHash, fontHash, align, bgHash)));

        require(royaltyRate <= royaltyRateMax, "CryptoBase: Not valid royalty");
        require(msg.value >= ethCreatePrice, "CryptoBase: Value is not enough");

        return createItem(_artNFT, tokenURI, royaltyRate, _itemHash, true);
    }

    // 上架艺术品或者下架艺术品（通过_price=0或者_pricetoken=0x0控制）
    function putItemOnSaleOrOff(address _artNFT, uint256 _nftId, uint256 _price, address _priceToken)
    external returns (bool) {
        require(artNFTMap[_artNFT], "NFT is not supported");
        require(_acceptedToken[_priceToken], "CryptoBase: not accept this token");

        MarketItem storage item = idToMarketItem[_artNFT][_nftId];

        require(msg.sender == item.owner, "CryptoBase: not authorized to operate this item");
        uint256 oldPrice = item.price;
        address oldPriceToken = item.priceToken;
        if (_price > 0 && _priceToken != address(0x0)) {
            item.price = _price;
            item.priceToken = _priceToken;
            item.isOnSale = true;
            emit CBOnSale(_artNFT, _nftId, oldPriceToken, oldPrice, _priceToken, _price);
        } else {
            item.isOnSale = false;
            emit CBOffSale(_artNFT, _nftId, item.priceToken,item.price);
        }
        
        return true;
    }

    // 购买艺术品
    function buyItem(address _artNFT, uint256 _nftId) public payable returns (bool) {
        require(artNFTMap[_artNFT], "NFT is not supported");
         
        MarketItem storage item = idToMarketItem[_artNFT][_nftId];
        require(
            item.isOnSale && item.price > 0 && item.priceToken != address(0x0),
            "art not for sale"
        );

        require(
            msg.sender != item.owner && msg.sender != owner(),
            "CryptoBase: contract owner can't buy or you already bought this art"
        );

        // 售价
        uint256 price = item.price;
        // 手续费
        uint256 fee = price.mul(swapFeeRate).div(10000);
        // 版税
        uint256 royalty = price.mul(item.royaltyRate).div(10000);
        // 剩余价值
        uint256 income = price.sub(fee).sub(royalty);

        if (item.priceToken == address(ETH_ADDRESS)) {
            require(msg.value >= price, "CryptoBase: You need to have enough Ether");
            
            cbholder.addTradeFee{value:fee}(address(ETH_ADDRESS), fee);
            // 作者收取版费
            payable(item.author).transfer(royalty);
            // 卖家获得剩余价值
            payable(item.owner).transfer(income);
        } else {
            IERC20 erc20 = IERC20(item.priceToken);
            uint256 balance = erc20.balanceOf(msg.sender);

            require(balance >= price, "CryptoBase: Not enough to buy");
            erc20.transferFrom(msg.sender, address(this), price);
            // 平台收取手续费
            erc20.approve(address(this), price);
            erc20.transfer(address(cbholder), fee);
            cbholder.addTradeFee(item.priceToken, fee);
            // 作者收取版费
            erc20.transfer(item.author, royalty);
            // 卖家获得剩余价值
            erc20.transfer(item.owner, income);
        }
        address oldOwner = item.owner; 
        // 修改拥有者信息
        item.owner = payable(msg.sender);
        // 交易完成，下架
        item.isOnSale = false;

        // 调用ArtNFT转换拥有者
        IArtNFT(_artNFT).exchange(item.nftId, msg.sender);
        emit CBExchanged(_artNFT, _nftId, oldOwner, item.owner, item.priceToken, item.price);
        return true;
    }

    // 创作艺术品-私有
    function createItem(address _artNFT, string memory _tokenURI, uint256 _royaltyRate, uint256 _itemHash, bool _isPayWithEth)
    private returns (uint256){
        require(artNFTMap[_artNFT], "NFT is not supported");
        // 检查是否重复
        require(!isExistHash(_artNFT, _itemHash), "CryptoBase: this art is already exist");

        if (_isPayWithEth) {            
            cbholder.addCreateFee{value:ethCreatePrice}(address(ETH_ADDRESS), ethCreatePrice);
        } else {
            IERC20 erc20token = IERC20(xhgt);

            erc20token.transferFrom(msg.sender, address(this), xhgtCreatePrice);
            erc20token.approve(address(this), xhgtCreatePrice);
            erc20token.transfer(address(cbholder), xhgtCreatePrice);            
            cbholder.addCreateFee(xhgt, xhgtCreatePrice);
        }

        // 调用ArtNFT创建NFT
        uint256 _artNFTId = IArtNFT(_artNFT).create(_tokenURI, _itemHash, msg.sender);

        idToMarketItem[_artNFT][_artNFTId] = MarketItem(
            _artNFTId, // 物品的合约tokenId
            payable(msg.sender), // 作者
            _royaltyRate, // 版税比率：每次交易额的百分比：单位 万分之N
            payable(msg.sender), // 所有者
            0, // 出售价格
            address(0x0), // 使用币的类型
            false // 是否在出售
        );

        itemHash[_artNFT][_itemHash] = true;

        emit CBMinted(
            _artNFT, _artNFTId, _tokenURI, msg.sender,
            _royaltyRate, _itemHash, _isPayWithEth, ethCreatePrice
        );

        return _artNFTId;
    }

    function isExistHash(address _artNFT, uint256 _itemHash) private view returns (bool) {
        if (itemHash[_artNFT][_itemHash]) return true;

        return false;
    }
 
}