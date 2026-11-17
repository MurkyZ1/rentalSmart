# SmartLiving Property — Smart Property Rental & Deposit Management

ระบบจัดการสัญญาเช่าอสังหาริมทรัพย์และเงินประกันบน Blockchain (โจทย์ที่ 4)
พัฒนาด้วย **Solidity (Remix IDE)** และ **Frontend HTML + ethers.js + MetaMask**

🌐 **หน้าเว็บ:** <https://murkyz1.github.io/rentalSmart/>

## ผู้จัดทำ

| รหัสนักศึกษา | ชื่อ-นามสกุล |
|---|---|
| 66065761 | ภูวนาท ศรุตติ์ตานนทร์ |
| 66102316 | คิรากร สุวรรณโกสุม |

---

## สถานการณ์ทางธุรกิจ

บริษัท SmartLiving Property บริหารห้องพักและอพาร์ตเมนต์ให้เช่ากว่า 200 ห้อง และเจอปัญหาหลายอย่าง:

- การจัดเก็บเงินประกันไม่โปร่งใส
- เงื่อนไขการคืนเงินไม่ชัดเจน
- เกิดข้อโต้แย้งระหว่างเจ้าของห้องกับผู้เช่าเมื่อสิ้นสุดสัญญา

ระบบนี้ใช้ Smart Contract ถือเงินประกันไว้แทนคนกลาง ทั้งสองฝ่ายตรวจสอบเงื่อนไขร่วมกันได้ และทุกธุรกรรมบันทึกบน Blockchain ย้อนหลังได้

---

## โครงสร้างไฟล์

```
├── SmartRental.sol   # Smart Contract (Deploy ผ่าน Remix)
├── index.html        # Frontend (เชื่อมต่อผ่าน MetaMask)
└── README.md
```

---

## บทบาทผู้ใช้ (Roles)

| บทบาท | คำอธิบาย |
|---|---|
| **เจ้าของห้อง (Landlord)** | ลงทะเบียนห้อง สร้างสัญญา ตรวจสภาพห้อง และเสนอยอดคืนเงินประกัน |
| **ผู้เช่า (Tenant)** | ยืนยันสัญญา ฝากเงินประกัน ชำระค่าเช่า ยอมรับยอดคืนหรือแจ้งข้อพิพาท |
| **ผู้มีอำนาจ (Arbitrator)** | Wallet ที่ Deploy Contract มีหน้าที่พิจารณาข้อพิพาทและปล่อยเงิน (เปลี่ยนได้ด้วย `setArbitrator`) |

---

## ฟังก์ชันตาม Functional Requirements

| # | Requirement | ฟังก์ชัน | ผู้เรียก |
|---|---|---|---|
| 1 | ลงทะเบียนทรัพย์สิน | `registerProperty(name, location, rentAmount, depositAmount)` | เจ้าของห้อง |
| 2 | สร้างสัญญาเช่า | `createAgreement(propertyId, tenant, startDate, endDate, terms)` | เจ้าของห้อง |
| 3 | ยืนยันสัญญา | `confirmAgreement(id)` / `cancelAgreement(id)` | ทั้งสองฝ่าย |
| 4 | ฝากเงินประกัน | `depositSecurity(id)` *payable* | ผู้เช่า |
| 5 | บันทึกค่าเช่า | `payRent(id, period)` *payable* / `getPayments(id)` | ผู้เช่า |
| 6 | คืนเงินประกัน | `endAgreement(id)` → `proposeRefund(id, deduction, reason)` → `acceptRefund(id)` | ทั้งสองฝ่าย / เจ้าของ / ผู้เช่า |
| 7 | จัดการข้อพิพาท | `raiseDispute(id, reason)` → `resolveDispute(id, deduction, resolution)` | ทั้งสองฝ่าย / Arbitrator |

ฟังก์ชันสำหรับอ่านข้อมูล (View) ได้แก่ `getProperty`, `getAgreement`, `getPayments`, `getProposal`, `getSettlement`, `getDispute`, `contractBalance`, `periodPaid`

---

## สถานะของสัญญา (Agreement Lifecycle)

```
 Pending ──(ยืนยันครบ 2 ฝ่าย)──► Confirmed ──(ฝากเงินประกัน)──► Active
    │                               │                            │
    └───────(ยกเลิก)────► Cancelled ◄┘                (ถึงวันสิ้นสุด) endAgreement
                                                                 ▼
                         Closed ◄──(ผู้เช่ายอมรับ)── RefundProposed ◄── Ended
                           ▲                              │              │
                           │                        raiseDispute    raiseDispute
                           │                              ▼              │
                           └────(Arbitrator ตัดสิน)──── Disputed ◄────────┘
```

| ค่า | สถานะ | ความหมาย |
|---|---|---|
| 0 | Pending | รอทั้งสองฝ่ายยืนยัน |
| 1 | Confirmed | ยืนยันครบแล้ว รอฝากเงินประกัน |
| 2 | Active | สัญญามีผล ชำระค่าเช่าได้ |
| 3 | Ended | สิ้นสุดสัญญา รอตรวจสภาพห้อง |
| 4 | RefundProposed | เจ้าของห้องเสนอยอดคืนแล้ว |
| 5 | Disputed | มีข้อพิพาท เงินถูกล็อกจนกว่าจะตัดสิน |
| 6 | Closed | ปิดสัญญาและคืนเงินแล้ว |
| 7 | Cancelled | ยกเลิกก่อนสัญญามีผล |

---

## กฎทางธุรกิจที่บังคับใน Smart Contract

1. **การหักเงินประกันต้องมีเหตุผล** ถ้ายอดหักมากกว่า 0 แต่ไม่ระบุเหตุผล ธุรกรรมจะถูกปฏิเสธ
2. **การหักเงินต้องได้รับอนุมัติ** โดยผู้เช่ากดยอมรับ (`acceptRefund`) หรือ Arbitrator ตัดสิน (`resolveDispute`) เจ้าของห้องถอนเงินประกันเองฝ่ายเดียวไม่ได้
3. **ห้ามคืนหรือหักเงินเกินยอดคงเหลือ** ทุกจุดตรวจ `deduction <= depositBalance` และเงินจะถูกแบ่งออกจนครบยอดเสมอ จึงไม่มีเงินค้างใน Contract
4. **ยอดเงินต้องตรงตามสัญญา** เงินประกันและค่าเช่าต้องโอนตรงกับยอดที่ระบุในสัญญาพอดี
5. **จ่ายค่าเช่างวดเดียวกันซ้ำไม่ได้** (`periodPaid`)
6. **ค่าเช่าและเงินประกันถูกบันทึกไว้ตอนทำสัญญา** การแก้ราคาห้องภายหลังจึงไม่กระทบสัญญาเดิม
7. **ความปลอดภัย** ใช้ `nonReentrant` และอัปเดตสถานะก่อนโอนเงินเสมอ (Checks-Effects-Interactions)

---

## วิธีติดตั้งและใช้งาน

### สิ่งที่ต้องมี
- เบราว์เซอร์ที่ติดตั้ง [MetaMask](https://metamask.io)
- ETH บน Testnet เช่น Sepolia (ขอได้จาก Faucet) หรือรัน Ganache ในเครื่อง
- Node.js สำหรับเปิด local server (ไม่บังคับ)

### 1. Deploy Smart Contract ด้วย Remix
1. เปิด <https://remix.ethereum.org>
2. สร้างไฟล์ `SmartRental.sol` แล้ววางโค้ดลงไป
3. ไปที่แท็บ **Solidity Compiler** เลือกเวอร์ชัน `0.8.20` ขึ้นไป แล้วกด **Compile**
4. ไปที่แท็บ **Deploy & Run Transactions**
   - Environment: **Injected Provider - MetaMask**
   - กด **Deploy** แล้วยืนยันใน MetaMask
5. Copy **Contract Address** จากช่อง Deployed Contracts

> หมายเหตุ: ถ้าเลือก Environment เป็น Remix VM จะทดสอบใน Remix ได้ แต่ Frontend จะเชื่อมต่อไม่ได้

### 2. เปิด Frontend
**ใช้งานออนไลน์:** เปิด <https://murkyz1.github.io/rentalSmart/> ได้ทันที

**หรือรันในเครื่อง:** ต้องเปิดผ่าน local server เพราะ MetaMask ไม่ทำงานกับไฟล์ที่เปิดแบบ `file://`

```bash
npx serve .
# หรือใช้ Live Server ใน VS Code
```

เปิด `http://localhost:3000` จากนั้น:

1. กด **เชื่อมต่อ MetaMask**
2. วาง Contract Address แล้วกด **โหลด Contract**

---

## ตัวอย่างการทดสอบแบบครบ Flow

เตรียม MetaMask ไว้ 3 Account:
- **A** = Arbitrator (คนที่ Deploy)
- **B** = เจ้าของห้อง
- **C** = ผู้เช่า

| ขั้น | Account | การกระทำ |
|---|---|---|
| 1 | B | ลงทะเบียนห้อง ค่าเช่า 0.01 ETH เงินประกัน 0.02 ETH |
| 2 | B | สร้างสัญญาให้ C และ **ตั้งวันสิ้นสุดเป็นอีก 2–3 นาทีข้างหน้า** เพื่อทดสอบให้เร็ว |
| 3 | B, C | แต่ละคนกด "ยืนยันยอมรับเงื่อนไข" |
| 4 | C | ฝากเงินประกัน 0.02 ETH |
| 5 | C | ชำระค่าเช่างวดที่ 1 |
| 6 | B หรือ C | หลังถึงวันสิ้นสุด กด "สิ้นสุดสัญญา" |
| 7a | B | เสนอยอดหัก 0.005 ETH พร้อมเหตุผล "หลอดไฟเสีย" |
| 7b | C | กดยอมรับ (ปิดสัญญา) **หรือ** แจ้งข้อพิพาท |
| 8 | A | ถ้ามีข้อพิพาท บันทึกผลการพิจารณาและปล่อยเงิน |

สลับ Account ใน MetaMask ได้เลย ปุ่มในหน้าเว็บจะเปลี่ยนตามบทบาทของ Account นั้นโดยอัตโนมัติ

### ทดสอบผ่าน Remix โดยตรง
- จำนวนเงินต้องใส่เป็น **wei** เช่น `0.01 ETH = 10000000000000000`
- วันที่ต้องใส่เป็น **Unix timestamp (วินาที)** ดูได้ที่ <https://www.epochconverter.com>
- ตอนเรียก `depositSecurity` และ `payRent` ต้องใส่จำนวนเงินในช่อง **VALUE** ด้วย

---

## ความสามารถของ Frontend

- เชื่อมต่อ MetaMask และแสดงบทบาทของผู้ใช้ (เจ้าของ / ผู้เช่า / Arbitrator)
- ฟอร์มลงทะเบียนห้องและสร้างสัญญา (กรอกเป็น ETH และวันที่ปฏิทิน)
- การ์ดสัญญาแสดงสถานะ แถบความคืบหน้า คู่สัญญา เงินประกันคงเหลือ และเงื่อนไข
- ปุ่มดำเนินการเปลี่ยนตามบทบาทและสถานะของสัญญา
- ประวัติการชำระค่าเช่ารายงวด
- แท็บ **ประวัติธุรกรรม** อ่านจาก Event บน Blockchain เพื่อตรวจสอบย้อนหลัง
- ตัวกรอง: เฉพาะที่เกี่ยวกับฉัน / ทั้งหมด / มีข้อพิพาท

---

## Events ที่บันทึกบน Blockchain

`PropertyRegistered`, `AgreementCreated`, `AgreementConfirmed`, `AgreementFullyConfirmed`, `AgreementCancelled`, `DepositPaid`, `RentPaid`, `AgreementEnded`, `RefundProposed`, `DisputeRaised`, `DisputeResolved`, `DepositSettled`, `ArbitratorChanged`

---

## ผลลัพธ์ที่คาดหวัง

- การจัดการเงินประกันโปร่งใส เพราะเงินอยู่ใน Smart Contract ไม่ได้อยู่กับฝ่ายใดฝ่ายหนึ่ง
- ข้อพิพาทลดลง เพราะเงื่อนไขและการยืนยันของทั้งสองฝ่ายบันทึกไว้ถาวร
- ตรวจสอบประวัติธุรกรรมย้อนหลังได้ทุกรายการผ่าน Event และ Block Explorer

---

## Tech Stack

- Solidity ^0.8.20
- Remix IDE
- ethers.js v6
- MetaMask
- HTML / CSS / JavaScript (ไฟล์เดียว ไม่ต้อง build)
