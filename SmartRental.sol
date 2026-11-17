// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  SmartLiving Property - Smart Property Rental & Deposit Management
 * @notice ระบบจัดการสัญญาเช่าอสังหาริมทรัพย์และเงินประกันบน Blockchain
 *
 *  Flow หลัก:
 *   1. registerProperty   (เจ้าของห้อง)   ลงทะเบียนห้อง ค่าเช่า เงินประกัน
 *   2. createAgreement    (เจ้าของห้อง)   สร้างสัญญา ระบุผู้เช่า วันเริ่ม/สิ้นสุด เงื่อนไข
 *   3. confirmAgreement   (ทั้งสองฝ่าย)   ยืนยันเงื่อนไขด้วย Wallet ของตน
 *   4. depositSecurity    (ผู้เช่า)        โอนเงินประกัน (ETH) เข้า Contract
 *   5. payRent            (ผู้เช่า)        ชำระค่าเช่ารายงวด -> โอนต่อให้เจ้าของทันที + บันทึกประวัติ
 *   6. endAgreement       (ทั้งสองฝ่าย)   เมื่อถึงวันสิ้นสุดสัญญา -> รอตรวจสภาพห้อง
 *      proposeRefund      (เจ้าของห้อง)   เสนอยอดหัก + เหตุผล หลังตรวจห้อง
 *      acceptRefund       (ผู้เช่า)        ยอมรับ -> Contract คืนเงินอัตโนมัติ
 *   7. raiseDispute       (ทั้งสองฝ่าย)   โต้แย้ง -> resolveDispute (ผู้มีอำนาจ/Arbitrator) ตัดสินแล้วปล่อยเงิน
 *
 *  กฎทางธุรกิจ:
 *   - การหักเงินประกันต้องมีเหตุผล และต้องได้รับการอนุมัติ (ผู้เช่ายอมรับ หรือ Arbitrator ตัดสิน)
 *   - ไม่สามารถหัก/คืนเงินเกินยอดคงเหลือของเงินประกันได้
 */
contract SmartRental {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------
    enum Status {
        Pending,        // 0 สร้างแล้ว รอทั้งสองฝ่ายยืนยัน
        Confirmed,      // 1 ยืนยันครบ รอผู้เช่าฝากเงินประกัน
        Active,         // 2 สัญญามีผล
        Ended,          // 3 สิ้นสุดสัญญา รอตรวจสภาพห้อง
        RefundProposed, // 4 เจ้าของเสนอยอดคืนแล้ว รอผู้เช่ายอมรับ
        Disputed,       // 5 มีข้อพิพาท รอผู้มีอำนาจตัดสิน
        Closed,         // 6 ปิดสัญญา คืนเงินประกันเรียบร้อย
        Cancelled       // 7 ยกเลิกก่อนสัญญามีผล
    }

    struct Property {
        uint256 id;
        address owner;
        string name;
        string location;
        uint256 rentAmount;     // wei / งวด
        uint256 depositAmount;  // wei
        bool available;
    }

    struct Agreement {
        uint256 id;
        uint256 propertyId;
        address landlord;
        address tenant;
        uint256 rentAmount;     // snapshot ณ วันทำสัญญา
        uint256 depositAmount;  // snapshot ณ วันทำสัญญา
        uint256 startDate;      // unix timestamp
        uint256 endDate;        // unix timestamp
        string terms;           // เงื่อนไขสำคัญ
        bool landlordConfirmed;
        bool tenantConfirmed;
        uint256 depositBalance; // เงินประกันคงเหลือใน Contract
        uint256 totalRentPaid;
        Status status;
    }

    struct Payment {
        uint256 period;   // งวดที่
        uint256 amount;
        uint256 paidAt;
    }

    struct RefundDecision {
        uint256 refundToTenant;
        uint256 deduction;
        string reason;
        address decidedBy;
        uint256 decidedAt;
    }

    struct Dispute {
        address raisedBy;
        string reason;
        uint256 raisedAt;
        bool resolved;
        string resolution;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------
    address public arbitrator; // ผู้มีอำนาจพิจารณาข้อพิพาท (ค่าเริ่มต้น = ผู้ Deploy)
    uint256 public propertyCount;
    uint256 public agreementCount;

    mapping(uint256 => Property) private _properties;
    mapping(uint256 => Agreement) private _agreements;
    mapping(uint256 => Payment[]) private _payments;
    mapping(uint256 => mapping(uint256 => bool)) public periodPaid;
    mapping(uint256 => RefundDecision) private _proposals;   // ข้อเสนอของเจ้าของห้อง
    mapping(uint256 => RefundDecision) private _settlements; // ผลสุดท้ายที่ปล่อยเงินแล้ว
    mapping(uint256 => Dispute) private _disputes;

    bool private _locked;

    // ------------------------------------------------------------------
    // Events (ใช้ตรวจสอบประวัติย้อนหลัง)
    // ------------------------------------------------------------------
    event PropertyRegistered(uint256 indexed propertyId, address indexed owner, string name, uint256 rentAmount, uint256 depositAmount);
    event AgreementCreated(uint256 indexed agreementId, uint256 indexed propertyId, address indexed tenant, address landlord, uint256 startDate, uint256 endDate);
    event AgreementConfirmed(uint256 indexed agreementId, address indexed by);
    event AgreementFullyConfirmed(uint256 indexed agreementId);
    event AgreementCancelled(uint256 indexed agreementId, address indexed by);
    event DepositPaid(uint256 indexed agreementId, address indexed tenant, uint256 amount);
    event RentPaid(uint256 indexed agreementId, address indexed tenant, uint256 period, uint256 amount);
    event AgreementEnded(uint256 indexed agreementId, address indexed by);
    event RefundProposed(uint256 indexed agreementId, uint256 refundToTenant, uint256 deduction, string reason);
    event DisputeRaised(uint256 indexed agreementId, address indexed by, string reason);
    event DisputeResolved(uint256 indexed agreementId, address indexed arbitrator, uint256 deduction, string resolution);
    event DepositSettled(uint256 indexed agreementId, uint256 refundToTenant, uint256 deductionToLandlord, address indexed approvedBy);
    event ArbitratorChanged(address indexed oldArbitrator, address indexed newArbitrator);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------
    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Only arbitrator");
        _;
    }

    modifier nonReentrant() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier agreementExists(uint256 id) {
        require(id > 0 && id <= agreementCount, "Agreement not found");
        _;
    }

    modifier onlyParty(uint256 id) {
        Agreement storage a = _agreements[id];
        require(msg.sender == a.landlord || msg.sender == a.tenant, "Not a party of this agreement");
        _;
    }

    constructor() {
        arbitrator = msg.sender;
    }

    // ------------------------------------------------------------------
    // 1. Register Property
    // ------------------------------------------------------------------
    function registerProperty(
        string calldata name,
        string calldata location,
        uint256 rentAmount,
        uint256 depositAmount
    ) external returns (uint256 id) {
        require(bytes(name).length > 0, "Name required");
        require(rentAmount > 0, "Rent must be > 0");
        require(depositAmount > 0, "Deposit must be > 0");

        id = ++propertyCount;
        _properties[id] = Property(id, msg.sender, name, location, rentAmount, depositAmount, true);
        emit PropertyRegistered(id, msg.sender, name, rentAmount, depositAmount);
    }

    /// เจ้าของแก้ไขค่าเช่า/เงินประกันได้เฉพาะตอนห้องว่าง (ไม่กระทบสัญญาเดิม)
    function updateProperty(uint256 propertyId, uint256 rentAmount, uint256 depositAmount) external {
        Property storage p = _properties[propertyId];
        require(p.id != 0, "Property not found");
        require(p.owner == msg.sender, "Only property owner");
        require(p.available, "Property is under agreement");
        require(rentAmount > 0 && depositAmount > 0, "Amounts must be > 0");
        p.rentAmount = rentAmount;
        p.depositAmount = depositAmount;
    }

    // ------------------------------------------------------------------
    // 2. Create Rental Agreement
    // ------------------------------------------------------------------
    function createAgreement(
        uint256 propertyId,
        address tenant,
        uint256 startDate,
        uint256 endDate,
        string calldata terms
    ) external returns (uint256 id) {
        Property storage p = _properties[propertyId];
        require(p.id != 0, "Property not found");
        require(p.owner == msg.sender, "Only property owner");
        require(p.available, "Property not available");
        require(tenant != address(0) && tenant != msg.sender, "Invalid tenant");
        require(endDate > startDate, "End date must be after start date");

        id = ++agreementCount;
        Agreement storage a = _agreements[id];
        a.id = id;
        a.propertyId = propertyId;
        a.landlord = msg.sender;
        a.tenant = tenant;
        a.rentAmount = p.rentAmount;
        a.depositAmount = p.depositAmount;
        a.startDate = startDate;
        a.endDate = endDate;
        a.terms = terms;
        a.status = Status.Pending;

        p.available = false;
        emit AgreementCreated(id, propertyId, tenant, msg.sender, startDate, endDate);
    }

    // ------------------------------------------------------------------
    // 3. Confirm Agreement
    // ------------------------------------------------------------------
    function confirmAgreement(uint256 id) external agreementExists(id) onlyParty(id) {
        Agreement storage a = _agreements[id];
        require(a.status == Status.Pending, "Agreement not pending");

        if (msg.sender == a.landlord) {
            require(!a.landlordConfirmed, "Landlord already confirmed");
            a.landlordConfirmed = true;
        } else {
            require(!a.tenantConfirmed, "Tenant already confirmed");
            a.tenantConfirmed = true;
        }
        emit AgreementConfirmed(id, msg.sender);

        if (a.landlordConfirmed && a.tenantConfirmed) {
            a.status = Status.Confirmed;
            emit AgreementFullyConfirmed(id);
        }
    }

    /// ยกเลิกได้เฉพาะก่อนฝากเงินประกัน
    function cancelAgreement(uint256 id) external agreementExists(id) onlyParty(id) {
        Agreement storage a = _agreements[id];
        require(a.status == Status.Pending || a.status == Status.Confirmed, "Cannot cancel at this stage");
        a.status = Status.Cancelled;
        _properties[a.propertyId].available = true;
        emit AgreementCancelled(id, msg.sender);
    }

    // ------------------------------------------------------------------
    // 4. Deposit Security
    // ------------------------------------------------------------------
    function depositSecurity(uint256 id) external payable agreementExists(id) {
        Agreement storage a = _agreements[id];
        require(msg.sender == a.tenant, "Only tenant");
        require(a.status == Status.Confirmed, "Agreement not confirmed by both parties");
        require(msg.value == a.depositAmount, "Incorrect deposit amount");

        a.depositBalance = msg.value;
        a.status = Status.Active;
        emit DepositPaid(id, msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // 5. Record Rental Payment
    // ------------------------------------------------------------------
    function payRent(uint256 id, uint256 period) external payable agreementExists(id) nonReentrant {
        Agreement storage a = _agreements[id];
        require(msg.sender == a.tenant, "Only tenant");
        require(a.status == Status.Active, "Agreement not active");
        require(period > 0, "Period must start at 1");
        require(!periodPaid[id][period], "Period already paid");
        require(msg.value == a.rentAmount, "Incorrect rent amount");

        periodPaid[id][period] = true;
        a.totalRentPaid += msg.value;
        _payments[id].push(Payment(period, msg.value, block.timestamp));

        (bool ok, ) = payable(a.landlord).call{value: msg.value}("");
        require(ok, "Rent transfer failed");
        emit RentPaid(id, msg.sender, period, msg.value);
    }

    // ------------------------------------------------------------------
    // 6. End agreement & Refund Deposit
    // ------------------------------------------------------------------
    function endAgreement(uint256 id) external agreementExists(id) onlyParty(id) {
        Agreement storage a = _agreements[id];
        require(a.status == Status.Active, "Agreement not active");
        require(block.timestamp >= a.endDate, "Agreement period not finished");
        a.status = Status.Ended;
        emit AgreementEnded(id, msg.sender);
    }

    /// เจ้าของห้องเสนอยอดหักหลังตรวจสภาพห้อง (deduction = 0 คือคืนเต็มจำนวน)
    function proposeRefund(uint256 id, uint256 deduction, string calldata reason) external agreementExists(id) {
        Agreement storage a = _agreements[id];
        require(msg.sender == a.landlord, "Only landlord");
        require(a.status == Status.Ended, "Inspection stage required");
        require(deduction <= a.depositBalance, "Deduction exceeds deposit balance");
        if (deduction > 0) {
            require(bytes(reason).length > 0, "Reason required for deduction");
        }

        uint256 refund = a.depositBalance - deduction;
        _proposals[id] = RefundDecision(refund, deduction, reason, msg.sender, block.timestamp);
        a.status = Status.RefundProposed;
        emit RefundProposed(id, refund, deduction, reason);
    }

    /// ผู้เช่ายอมรับยอดที่เสนอ -> ระบบคืนเงินทันที
    function acceptRefund(uint256 id) external agreementExists(id) nonReentrant {
        Agreement storage a = _agreements[id];
        require(msg.sender == a.tenant, "Only tenant");
        require(a.status == Status.RefundProposed, "No refund proposal");
        RefundDecision memory p = _proposals[id];
        _settle(id, p.deduction, p.reason, msg.sender);
    }

    // ------------------------------------------------------------------
    // 7. Rental Dispute
    // ------------------------------------------------------------------
    function raiseDispute(uint256 id, string calldata reason) external agreementExists(id) onlyParty(id) {
        Agreement storage a = _agreements[id];
        require(a.status == Status.Ended || a.status == Status.RefundProposed, "Cannot dispute at this stage");
        require(bytes(reason).length > 0, "Reason required");

        _disputes[id] = Dispute(msg.sender, reason, block.timestamp, false, "");
        a.status = Status.Disputed;
        emit DisputeRaised(id, msg.sender, reason);
    }

    /// ผู้มีอำนาจตัดสิน: กำหนดยอดหักให้เจ้าของห้อง ที่เหลือคืนผู้เช่า
    function resolveDispute(uint256 id, uint256 deduction, string calldata resolution)
        external
        onlyArbitrator
        agreementExists(id)
        nonReentrant
    {
        Agreement storage a = _agreements[id];
        require(a.status == Status.Disputed, "No active dispute");
        require(bytes(resolution).length > 0, "Resolution required");
        require(deduction <= a.depositBalance, "Deduction exceeds deposit balance");

        Dispute storage d = _disputes[id];
        d.resolved = true;
        d.resolution = resolution;
        emit DisputeResolved(id, msg.sender, deduction, resolution);

        _settle(id, deduction, resolution, msg.sender);
    }

    function _settle(uint256 id, uint256 deduction, string memory reason, address approvedBy) private {
        Agreement storage a = _agreements[id];
        uint256 balance = a.depositBalance;
        require(deduction <= balance, "Deduction exceeds deposit balance");
        uint256 refund = balance - deduction;

        // Effects ก่อน Interactions (ป้องกัน reentrancy / จ่ายซ้ำ)
        a.depositBalance = 0;
        a.status = Status.Closed;
        _properties[a.propertyId].available = true;
        _settlements[id] = RefundDecision(refund, deduction, reason, approvedBy, block.timestamp);

        if (refund > 0) {
            (bool ok1, ) = payable(a.tenant).call{value: refund}("");
            require(ok1, "Refund to tenant failed");
        }
        if (deduction > 0) {
            (bool ok2, ) = payable(a.landlord).call{value: deduction}("");
            require(ok2, "Transfer to landlord failed");
        }
        emit DepositSettled(id, refund, deduction, approvedBy);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------
    function setArbitrator(address newArbitrator) external onlyArbitrator {
        require(newArbitrator != address(0), "Invalid address");
        emit ArbitratorChanged(arbitrator, newArbitrator);
        arbitrator = newArbitrator;
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    function getProperty(uint256 id) external view returns (Property memory) {
        require(_properties[id].id != 0, "Property not found");
        return _properties[id];
    }

    function getAgreement(uint256 id) external view agreementExists(id) returns (Agreement memory) {
        return _agreements[id];
    }

    function getPayments(uint256 id) external view returns (Payment[] memory) {
        return _payments[id];
    }

    function getProposal(uint256 id) external view returns (RefundDecision memory) {
        return _proposals[id];
    }

    function getSettlement(uint256 id) external view returns (RefundDecision memory) {
        return _settlements[id];
    }

    function getDispute(uint256 id) external view returns (Dispute memory) {
        return _disputes[id];
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
