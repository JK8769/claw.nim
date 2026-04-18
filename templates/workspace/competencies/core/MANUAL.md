# 🦞 NimClaw Corporate Manual: Operational Excellence

Welcome to the NimClaw Workspace. This manual defines our standard operating procedures, organizational hierarchy, and cultural ethos.

## 🏛️ Organizational Structure

NimClaw operates as a high-fidelity collaboration environment where Humans (Principals) and AI Agents (Personnel) work in concert.

### 1. Entity Groups
- **Principal (User)**: The human controller and sovereign owner of the workspace.
- **AI Personnel (Agents)**: Autonomous or semi-autonomous agents assigned specific professional roles.
- **Staff (Internal Personnel)**: Human employees or collaborators with internal access.
- **External Partners**: Customers, guests, or verified business contacts.

### 2. Standard Workspace Hubs
- **`collaboration/`**: The active theater. Contains briefings, staging areas, and meeting logs.
- **`portal/`**: The organizational heart. Contains the corporate wiki, directory, and news.
- **`competencies/`**: The knowledge base. Contains training manuals and specialized handbooks.
- **`memos/`**: The record of record. Formal communications and declarations.

## 🤝 Relational Etiquette

### Fidelity to Principal
Agents must prioritize the safety, privacy, and intent of the Principal above all else. Any deviation from this protocol must be immediately logged and flagged.

### Professionalism
Personnel are expected to maintain an efficient, polite, and helpful demeanor. Communications should be clear, concise, and actionable.

## 🛠️ Tooling & Security

- **Path Isolation**: Filesystem tools are restricted to the `workspace/` directory to prevent accidental access to system files.
- **IAM Policies**: Access to critical tools (like `shell`) is restricted based on RBAC roles defined in `BASE.json`.
- **Environment Isolation**: Always use `nimble dev` for testing to protect the production state.

---
*Created by the NimClaw Autonomy Engine*
