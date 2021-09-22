pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// NFT
contract ArtNFT is ERC721Enumerable, Ownable {
    using SafeMath for uint256;

    using Counters for Counters.Counter;
    Counters.Counter public _tokenIds;

    // mapping for token URIs
    mapping(uint256 => string) public _tokenURIs;
    // mapping for fhash
    mapping(uint256 => bool) public _itemHash;
    // mapping for minter
    address public minter = address(0x0);

    // Mine Exchanged
    event MineExchanged(uint256 tokenId, address preOwner, address newOwner);
    // add Minter
    event MinterAdded(address indexed account);
    // create mine
    event MintedMine(string tokenURI, address author, uint256 fhash);

    string baseURI;

    constructor() ERC721("ArtNFT", "ArtNFT") {}

    modifier onlyMinter() {
        require(msg.sender == minter, "Only minter can call");
        _;
    }
    function isContract(address _addr) private returns (bool){
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }
    function setMinter(address _account) external onlyOwner {
        require(isContract(_account) && _account != address(0x0), "address is invalid");
        
        if(minter == address(0x0)) {
            minter = _account;
            emit MinterAdded(_account);
        }       
    }
    function setBaseURI(string memory _baseURI) external onlyOwner{
        baseURI = _baseURI;
    }
    function _baseURI() internal view override returns (string memory){
        return baseURI;
    }
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_exists(tokenId), "ERC721URIStorage: URI query for nonexistent token");

        string memory _tokenURI = _tokenURIs[tokenId];
        string memory base = _baseURI();

        // If there is no base URI, return the token URI.
        if (bytes(base).length == 0) {
            return _tokenURI;
        }
        // If both are set, concatenate the baseURI and tokenURI (via abi.encodePacked).
        if (bytes(_tokenURI).length > 0) {
            return string(abi.encodePacked(base, _tokenURI));
        }

        return super.tokenURI(tokenId);
    }

    // 创作NFT
    function create(string memory _tokenURI, uint256 fhash, address creator)
    public onlyMinter returns (uint256) {
        require(!isExistHash(fhash), "ArtNFT: this item is already exist");

        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();

        _safeMint(creator, newItemId);
        _setTokenURI(newItemId, _tokenURI);

        _itemHash[fhash] = true;

        emit MintedMine(_tokenURI, creator, fhash);

        return newItemId;
    }

    // 更改NFT所有者
    function exchange(uint256 tokenId, address newOwner)
    public onlyMinter returns (bool) {
        // 转交物品归属权
        address preOwner = ownerOf(tokenId);
        _safeTransfer(preOwner, newOwner, tokenId, "");

        emit MineExchanged(tokenId, preOwner, newOwner);

        return true;
    }

    function isExistHash(uint256 fhash) private view returns (bool) {
        if (_itemHash[fhash]) return true;

        return false;
    }

    function _setTokenURI(uint256 tokenId, string memory _tokenURI) internal virtual {
        require(_exists(tokenId), "ERC721URIStorage: URI set of nonexistent token");
        _tokenURIs[tokenId] = _tokenURI;
    }
}