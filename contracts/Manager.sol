pragma solidity 0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/* SUMMARY:
 * - 2 main different type depending on where the upgradeability mechanism resides: UUPS vs Transparent
 * - Use of EIP1967 to avoid storage clash (alternatively, extend implementation storage when upgrading
 *   instead of changing its storage layout) 
 * - Use an "admin" functionality to avoid function clash: to delegate or to not delegate
 *
 * REMAINING QUESTIONS:
 * - If a contract is OpenZeppelin Upgradeable what happens? What type of proxy becomes? Review OwnableUpgradeable
 * - How OZ _gap requirement for Upgradeability compliance fits here?
 * - If constructors don't work, why is it required the disableInitializers?
 * - Initialization of base contract when inheriting OZ upgradeble contracts?
 * - EIP1867: where and how to implement this --> isn't the storage set in proxy? 
 * - What happens with constant/immutable variables in implementations? Can they be set or won't work?
 * - In clones, how is storage configured if it's only delegatecalling?
 */

/* Transparent vs UUPS proxies:
 * The difference is in how the upgradeability is performed --> Proxy or Implementation
 *
 * TRANSPARENT PROXY: 
 * - Upgrade logic managed in proxy
 * - Require an admin mechanism to decide if a call should be executed in proxy or delegated
 * 
 * UUPS PROXY:
 * - Upgrade logic managed in implementation --> solidity compiler will complain if there is function selector clash
 * - Can be implemented by simply inheriting a common standard interface that includes
 *   upgradeability like OZ's UUPSUpgradeable interface
 * - Not including an upgradeability mechanism will lock the contract forever
 */


/* OTHER TYPES OF PROXIES: 
 *
 * DIAMOND PROXY:
 * - Proxys stores a mapping from fSelector => implementation address
 * - Allows going over max contract size
 * - More granular upgrades
 * - Storage clashes between implementations --> variant of EIP1967 where each implementation storage
 *   is defined as a struct and stored using EIP1967
 *
 * BEACON:
 * - Multiple proxies per implementation
 * - Each proxy stores the address of a beacon (instead of implementation), that holds the implementation address
 * - When the proxy receives the call, it asks the beacon which implementation to use
 * - Proxies don't need to keep their storage (no need for EIP1967)
 *
 * CLONE or MINIMAL PROXY:
 * - Factory-like pattern to create several proxies that simply delegateCall to the same Implementation
 * - Based on EIP1167
 * - They are not upgradeable, thus don't need storage or management functions
 *
 * METAMORPHIC CONTRACTS:
 * - Preserves the contract address among upgrades, but not its state
 * - Relies on the CREATE2 opcode introduced in EIP1014
 * - A contract address deployed using CREATE2 is determined by the contract deployment code, the sender and a salt
 * - Requires the selfdestruct opcode to clean the contract address to be updated
 * - seldestruct does not delete the contract until the end of the TX --> 2TXs are required to update the contract
 *   (one to destroy the old contract and another to deploy the new contract), introducing a downtime
 * - Does not require a Proxy or to change the constructor into an initializer
 */

contract DAOmanagerEIP712 is Ownable {
    
    struct Signer {
        bool isValid;
        uint256 nonce; //nonce is tight to address
    }

    uint256 public proposalId;
    mapping(address => Signer) public validSigners;
    mapping(uint256 => address) public proposals;
    
    event NewProposal(uint256 indexed _proposalId, address indexed _proposalAddress);
    event SignerAdded(address indexed _signer);
    event SignerDeleted(address indexed _signer);


    /**
    * OPEN ZEPPELIN - CLONES
    *
    * @dev https://eips.ethereum.org/EIPS/eip-1167[EIP 1167] is a standard for
    * deploying minimal proxy contracts, also known as "clones".
    *
    * > To simply and cheaply clone contract functionality in an immutable way, this standard specifies
    * > a minimal bytecode implementation that delegates all calls to a known, fixed address.
    *
    * The library includes functions to deploy a proxy using either `create` (traditional deployment) or `create2`
    * (salted deterministic deployment).
    *
    */

    function createProposal(address _newImplementation) external onlyOwner {
        address newImplementation = Clones.clone(_newImplementation);//@audit how is address returned??
        newImplementation.initialize()
        //newImplementation.call(msg.data) @audit challenge for msg.data/TX exercice
        proposals[proposalId] = newImplementation;
        proposalI++;
        emit ProposalCreated(_proposalId, _proposalAddress);
    }

    function addSigner(address _signer) external onlyOwner{
        validSigners[_signer].isValid = true;
        emit SignerAdded(_signer);
    }

    function deleteSigner(address _signer) external onlyOwner{
        validSigners[_signer].isValid = false;
        emit SignerDeleted(_signer);
    }

    function getProposal(uint256 _proposalId) external view returns (address){
        return proposals[_proposalId];
    }

    function isValidSigner(address _signer) external view returns (bool) {
        return validSigners[_signer].isValid;
    }

    function voteOnProposal(address _sender, uint256 _voteOption, uint256 _proposalId, bytes32 _signedHash, bytes32 r, bytes32 s, uint8 v, uint256 _nonce) external {
        require(_isValidHash(_voteOption, _signedHash, _nonce, _signedHash), "invalid hash");
        
        address signer = ecrecover(_signedHash, v, r, s);//if signed hash is diff and do not correspond to the sig, a different address is given
        require(signer == _sender, "incorrect signer");
        
        require(validSigners[signer].isValid, "voter has no permission");
        validSigners[signer].nonce += 1;
        _forwardVote(_voteOption, _proposalId, signer);
    }

    function _isValidHash(uint256 _voteOption, bytes32 _proposalId, uint256 _nonce, bytes32 _signedHash) private pure returns (bool) {
        bytes32 signedMessage = keccak256(abi.encodePacked(_voteOption, _proposalId, _nonce)); //encoded message to use in ethers.getSIgn
        bytes32 ethSignedMessage = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", signedMessage));
        if (ethSignedMessage == _signedHash){
            return true;
        }
        return false;
    }

    function _forwardVote(uint256 _voteOption, uint256 _proposalId, address _signer) private {
        (bool success, ) = proposals[_proposalId].call(abi.encodeWithSignature("Vote(uint256,address)", _voteOption, _signer));//how to input params here
        require(success, "unexpected error during call");
    }
}