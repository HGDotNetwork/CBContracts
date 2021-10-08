pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// NFT
interface ICryptoHolder {
    function addCreateFee(address _token, uint256 _amount) external payable;
}

contract Crypto721 is ERC721Enumerable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // mapping for token URIs
    string public baseURI;
    uint256 private tokenId;
    mapping(uint256 => string) private tokenURIs;
    mapping(uint256 => uint256) private tokenHashes;

    IERC20 immutable xhgt;
    ICryptoHolder immutable holder;

    uint256 public xhgtFee = 10 * 10**18;
    uint256 public etherFee = 0.01 ether;
    address constant etherAddr = 0x000000000000000000000000000000000000bEEF;
    uint256 immutable public maxSupply;
    uint256 immutable public maxDaySupply;
    uint256 public dayCount;
    uint256 public dayTime;

    address private operator;
    enum Operations { SET_OPERATOR, SET_FEE, SET_BASE_URI }
    uint256 private constant _TIMELOCK = 1 days;
    mapping(Operations => uint256) public timelock;

    event MintWithEther(address minter, string tokenURI, uint256 fileHash);
    event MintWithXhgt(address minter, string tokenURI, uint256 fileHash);

    modifier notLocked(Operations _fn) {
        require(timelock[_fn] != 0 && timelock[_fn] >= block.timestamp, "Operation is timelocked");
        _;
    }

    modifier onlyOperator(){
        require (msg.sender == operator, "Only operator can call");
        _;
    }

    constructor(IERC20 _xhgt, ICryptoHolder _holder, address _operator, uint256 _maxSupply, uint256 _maxDaySupply) ERC721("CryptoBaseArt", "CBA") {
        xhgt = _xhgt;
        holder = _holder;
        maxSupply = _maxSupply;
        maxDaySupply = _maxDaySupply;
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

    function setBaseURI(string memory _baseURI) external onlyOperator notLocked(Operations.SET_BASE_URI) {
        baseURI = _baseURI;
        timelock[Operations.SET_BASE_URI] = 0;
    }

    function setFee(uint256 _xhgtFee, uint256 _etherFee) external onlyOperator notLocked(Operations.SET_FEE) {
        xhgtFee = _xhgtFee;
        etherFee = _etherFee;
        timelock[Operations.SET_FEE] = 0;
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        string memory _tokenURI = tokenURIs[_tokenId];

        if (bytes(baseURI).length > 0) {
            return string(abi.encodePacked(baseURI, _tokenURI));
        }

        return _tokenURI;
    }

    function mintWithEther(string memory _tokenURI, string memory _fileHash) external payable {
        uint256 _tokenHash = uint256(keccak256(abi.encodePacked(_fileHash)));
        // 收取手续费
        holder.addCreateFee{value:etherFee}(address(etherAddr), etherFee);

        _mintNFT(_tokenURI, _tokenHash);

        emit MintWithEther(msg.sender, _tokenURI, _tokenHash);
    }

    function mintWithXhgt(string memory _tokenURI, string memory _fileHash) external {
        uint256 _tokenHash = uint256(keccak256(abi.encodePacked(_fileHash)));
        // 收取手续费
        xhgt.safeTransferFrom(msg.sender, address(holder), xhgtFee);
        holder.addCreateFee(address(xhgt), xhgtFee);

        // mint
        _mintNFT(_tokenURI, _tokenHash);

        emit MintWithXhgt(msg.sender, _tokenURI, _tokenHash);
    }

    function _mintNFT(string memory _tokenURI, uint256 _tokenHash) private {
        require(tokenHashes[_tokenHash] == 0, 'Repeat hash');
        require(bytes(_tokenURI).length > 0, 'Empty tokenURI');

        // 检查mint总量
        tokenId++;
        require(tokenId <= maxSupply, 'Mint over');
        // 检查每日mint数量
        if (block.timestamp - dayTime > 24 * 3600) {
            dayCount = 0;
            dayTime = block.timestamp;
        }
        dayCount++;
        require(dayCount <= maxDaySupply, 'No nft left today');

        tokenURIs[tokenId] = _tokenURI;
        tokenHashes[_tokenHash] = tokenId;
        _safeMint(msg.sender, tokenId);
    }
}
