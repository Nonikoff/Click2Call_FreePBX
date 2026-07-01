<p align="center">
  <img src="docs/Logo/Logo%20Badge.png" width="150" alt="Logo Badge">
</p>

# Click2Call API for FreePBX: Commercial Click-to-Call REST API compatible with FreePBX.

Empower your CRM, web portal, or custom application with seamless Click2Call functionality. This enterprise-grade REST API is designed to originate calls on any version of FreePBX, providing a robust bridge between your business software and your telephony infrastructure.

<p align="center">
  <img src="docs/Logo/Cover.png" alt="Cover" />
</p>

> **Disclaimer**
>
> Click2Call for FreePBX is an independent commercial product developed by Nonikoff.
> It is **not affiliated with, endorsed by, or supported by Sangoma Technologies or the FreePBX project.**

## 🚀 Key Features

- **Universal Click2Call**: Trigger calls between agent extensions and any destination with a single HTTP POST request.
- **Real-time Agent Status**: Monitor agent availability via PJSIP endpoint states directly from your application.
- **Enterprise-Grade Security**: Secure API Key authentication managed directly from the PBX shell.
- **Advanced Trunk Routing**: Supports complex outbound routing needs via service prefixes and granular CallerID overrides.
- **Intelligent Number Sanitization**: Automatically cleans destination numbers (removes non-digits and leading zeros) for maximum carrier compatibility.
- **Built for Scale**: High-performance native Asterisk Manager Interface (AMI) integration.
- **Lightweight Deployment**: Zero external database dependencies; runs natively within your FreePBX environment.

## 📦 How to Install (3-Minute Setup)

1. **Clone**: Clone this repository to your FreePBX server:
   ```bash
   git clone https://github.com/Nonikoff/Click2Call_FreePBX.git
   cd Click2Call_FreePBX
   ```
2. **Install**: Run the automated installer:
   ```bash
   sudo chmod +x install.sh
   sudo ./install.sh
   ```
3. **Authorize**: Generate your first API key using the CLI tool (see below).

## ⚙️ How It Works (Performance & Scale)

Unlike other solutions, Click2Call is designed for high-performance environments. It uses a decoupled monitoring architecture:

1.  **Background Worker**: A dedicated service polls the Asterisk Manager Interface (AMI) every 2 seconds for real-time PJSIP device states.
2.  **Database Caching**: Statuses are normalized and stored in a high-speed MariaDB cache, ensuring API responses are sub-millisecond and never put load on your telephony engine.
3.  **Real-time Correlation**: The API automatically correlates live device states with your **FreePBX User Manager** database, providing a seamless link between extensions and agent identities (emails/usernames).

### Agent Status Definitions
| Status | Meaning |
| :--- | :--- |
| `available` | Extension is online and ready to take a call. |
| `busy` | Extension is currently on a call, busy, or ringing. |
| `unavailable` | Extension is offline, unregistered, or unreachable. |

## 🛠 HTTP API Reference

### Click2Call
Initiate a call between an agent and a destination.
- **Endpoint**: `POST /api/v1/{api_key}/click2call`
- **Parameters**: `agent` (required), `number` (required), `sync` (optional boolean, default `false`)
- **Example**:
  ```bash
  curl -X POST "https://your-pbx/api/v1/MY-SECURE-KEY/click2call?agent=101&number=5550123&sync=true"
  ```
- **Example Response**:
  ```json
  {
    "call_id": "848a605f-7bc3-c3f2-1a4d-b9e123456789",
    "caller_id": "101",
    "extension": "101",
    "destination": "5550123",
    "sync": true,
    "status": "Success"
  }
  ```

### Agent Status
Monitor real-time agent availability.
- **Endpoint**: `GET /api/v1/{api_key}/agents_status`
- **Example Response**:
  ```json
  [
    { "ext": "101", "status": "available" }
  ]
  ```

### Error Responses
| Status | Error Message | Solution |
| :--- | :--- | :--- |
| **400** | `Invalid destination number` | Ensure number contains only 0-9, +, or spaces. |
| **400** | `Agent logged off` | No active PJSIP endpoints detected for this extension. |
| **403** | `Invalid API key` | Verify the key exists using the CLI management tool. |
| **500** | `AMI authentication failed` | Check Asterisk Manager credentials in FreePBX. |

## ⌨️ CLI Management Tool

Manage your integrations securely from the PBX shell using `manage_api_keys.php`.

| Command | Description |
| :--- | :--- |
| `--create-key` | Interactively create a new key and assign a routing CallerID. |
| `--list-keys` | Display all active keys, logins, and associated CallerIDs. |
| `--update-caller-id` | Change the routing prefix/CallerID for an existing key. |
| `--delete-key` | Instantly revoke access for a specific integration. |
| `--help` | Show all available management options. |

**Example**:
```bash
php /var/www/html/api/v1/manage_api_keys.php --list-keys
```

## 🛣️ Advanced Trunk Routing

Click2Call gives you absolute control over which trunk is used for an API call.

### Scenario 1: Multi-Provider (Prefix Based)
You can force different CRM departments to use different trunks by assigning unique CallerIDs (prefixes) to their API Keys.
1. Assign a prefix (e.g., `8001`) to an API Key via CLI.
2. In FreePBX **Outbound Routes**, create a route with:
   - **Prefix**: `8001`
   - **Trunk**: Your specific Provider Trunk.
3. The API automatically prepends this prefix to the destination number.

### Scenario 2: Single Provider
Simply leave the API Key CallerID empty or set it to your main outbound number. The call will follow your default FreePBX outbound rules.

## 📊 Professional Logging

Monitor your system in real-time using standard Linux tools:

- **API Traffic**: `tail -f /var/log/asterisk/click2call.log`
- **Presence Data**: `tail -f /var/log/asterisk/agents_status.log`
- **Security Audit**: `grep "ERROR" /var/log/asterisk/api_keys_management.log`

## 🔒 Infrastructure & Security

### Firewall Requirements
**IMPORTANT**: Your CRM/Application server IP address **MUST** be whitelisted in the FreePBX Firewall (Connectivity -> Firewall -> Networks) to allow HTTP traffic to the API endpoints.

### Authentication
Security is handled via unique **API Keys**. We do not use external tokens, ensuring your credentials never leave your private PBX environment.

## 🔐 Licensing & Pricing

FreePBX Click2Call is a commercial product. Our system automatically secures your installation based on your server's public IP.

### Pricing
- **Standard License**: **200 USDT / Year**
- **Extensions**: **Unlimited** (no per-user fees)

**To purchase a license or manage active subscriptions, you can use our Telegram bot:**
👉 **[@lic_c2c_pay_bot](https://t.me/lic_c2c_pay_bot)**

For other inquiries, trial requests, or custom support:
👉 **neat.list5884@fastmail.com**

FreePBX is a trademark of Sangoma Technologies.
This project is an independent product and is not affiliated with or endorsed by Sangoma.

---
*Developed for professionals who demand reliable FreePBX integrations.*
