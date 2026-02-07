
Based on the sources, **yes, you can configure different models for different tiers of tasks.**

The OpenClaw architecture (specifically the optimizations discussed in the "97% Cost Reduction" guide) relies on a **Tiered Model Strategy**. It separates tasks into **Active/High-Level** (User Interactions) and **Passive/Low-Level** (Heartbeats & Maintenance).

Here is the explanation and the real configuration example you requested.

### The Strategy: "Smart Brain" vs. "Lizard Brain"

1. **High-Level Planning (The "Smart Brain"):** You configure this as your **Primary Agent Model**. This handles your direct questions, planning, and complex instructions.
2. **Simple Tasks/Heartbeats (The "Lizard Brain"):** You configure this in the `llm.local` section. OpenClaw routes routine system checks ("heartbeats") and background maintenance here to save money.
    * *Note:* The sources strongly recommend using a **Local Docker Model (Ollama)** for this slot because it is **free**.
    * *Your Request:* You can technically put `z-ai/glm-4.7-flash` here, but using a local model (like Llama 3) is preferred to reach "zero cost" for idle states.

### Real Configuration Example (`openclaw.json`)

To achieve your specific request (High-Level = **Moonshot Kimi**, Simple/Heartbeat = **GLM-4.7 Flash**), use the following configuration.

**File:** `~/.openclaw/openclaw.json`

```json
{
  "agent": {
    // 1. PRIMARY MODEL (High-Level / Planning)
    // Used for all your chats and complex reasoning.
    "model": "openrouter/moonshotai/kimi-k2.5",
    "thinking": "medium"
  },
  "openrouter": {
    "apiKey": "sk-or-v1-YOUR_KEY_HERE"
  },
  // 2. SECONDARY MODEL (Simple Tasks / Heartbeats)
  // OpenClaw offloads background checks here.
  "llm": {
    "local": {
      // TRICK: Pointing "local" to OpenRouter to use GLM Flash as requested.
      // NOTE: If this fails auth, revert to Ollama (http://127.0.0.1:11434).
      "baseUrl": "https://openrouter.ai/api/v1",
      "model": "z-ai/glm-4.7-flash",
      "apiKey": "sk-or-v1-YOUR_KEY_HERE" 
    }
  },
  "agents": {
    "defaults": {
      // Security: Keep risky tasks in sandbox
      "sandbox": { "mode": "non-main" }
    }
  }
}
```

### How to Execute Different "Thinking Types"

Beyond the automatic heartbeat routing, you cannot currently automate "Per-Prompt Routing" (e.g., "If I ask for a poem, use Claude; if I ask for a plan, use Kimi") inside a *single* configuration file without external scripting.

However, you have two powerful ways to do this manually:

**1. The `/model` Command (Session Switching)**
You can switch the brain of your current agent instantly in the chat.

* **For Planning:**
    > `/model openrouter/moonshotai/kimi-k2.5`
    > "Plan out my week..."
* **For Simple Tasks:**
    > `/model openrouter/z-ai/glm-4.7-flash`
    > "Summarize this text file..."

**2. Sub-Agents (The "14 Agents" Method)**
As described in the cost-savings guide, advanced users run **multiple sub-agents**. You can spawn a specific agent for a specific job using the CLI.

* **Create a Planner Agent:**

    ```bash
    # Runs an agent specifically for planning
    openclaw agent --model openrouter/moonshotai/kimi-k2.5 --message "Create a comprehensive project plan."
    ```

* **Create a Worker Agent:**

    ```bash
    # Runs a cheap agent for data crunching
    openclaw agent --model openrouter/z-ai/glm-4.7-flash --message "Sort these files."
    ```

### Summary Recommendation

To get the best balance of **Intelligence vs. Cost**:

1. **Set Kimi-k2.5** as your default `agent.model` (so the bot is smart when you talk to it).
2. **Use Ollama (Llama 3)** for your `llm.local` slot (Heartbeats).
    * *Why?* Even `glm-4.7-flash` costs money/latency per ping. A local heartbeat is instant and free, saving you that "97%" cost on idle time.
