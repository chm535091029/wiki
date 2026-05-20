---
aliases: [Agent Memory Survey, AI Agent Memory, Forms Functions Dynamics, 智能体记忆综述, 记忆形式, 记忆功能, 记忆动力学]
tags: [AI-Memory, Agent, Survey, Token-level-Memory, Planar-Memory, Hierarchical-Memory, Parametric-Memory, Latent-Memory, KV-Cache, Token-Pruning, Adapter-based, Factual-Memory, Experiential-Memory, Working-Memory, Case-based-Memory, Strategy-based-Memory, Skill-based-Memory, Memory-Formation, Memory-Evolution, Memory-Retrieval, Catastrophic-Forgetting, Multi-Agent-Memory, Multimodal-Memory, RL-Memory, World-Model, Trustworthy-Memory, Cognitive-Science]
related:
  - "./claude-code-memory.md"
  - "../../RAG/llm-wiki/llm-wiki-combined-rag.md"
---

# Agent Memory in the Age of AI Agents: A Comprehensive Survey

> **Source Paper**: "Memory in the Age of AI Agents: A Survey — Forms, Functions and Dynamics"
> **Authors**: Yuyang Hu, Shichun Liu, Yanwei Yue, Guibin Zhang, et al. (National University of Singapore, Renmin University of China, Fudan University, Peking University, etc.)
> **arXiv**: arXiv:2512.13564v2 [cs.CL] 13 Jan 2026
> **GitHub**: https://github.com/Shichun-Liu/Agent-Memory-Paper-List

---

## Table of Contents

- [1. Introduction & Background](#1-introduction--background)
- [2. What is Agent Memory?](#2-what-is-agent-memory)
  - [2.1 Agent Memory vs. LLM Memory](#21-agent-memory-vs-llm-memory)
  - [2.2 Agent Memory vs. RAG](#22-agent-memory-vs-rag)
  - [2.3 Agent Memory vs. Context Engineering](#23-agent-memory-vs-context-engineering)
- [3. Form: What Carries Memory?](#3-form-what-carries-memory)
  - [3.1 Token-level Memory](#31-token-level-memory)
    - [Flat Memory (1D)](#flat-memory-1d)
    - [Planar Memory (2D)](#planar-memory-2d)
    - [Hierarchical Memory (3D)](#hierarchical-memory-3d)
  - [3.2 Parametric Memory](#32-parametric-memory)
    - [Internal Parametric Memory](#internal-parametric-memory)
    - [External Parametric Memory](#external-parametric-memory)
  - [3.3 Latent Memory](#33-latent-memory)
    - [Generate](#generate)
    - [Reuse](#reuse)
    - [Transform](#transform)
  - [3.4 Memory Form Adaptation Guide](#34-memory-form-adaptation-guide)
- [4. Functions: Why Agents Need Memory?](#4-functions-why-agents-need-memory)
  - [4.1 Factual Memory](#41-factual-memory)
    - [User Factual Memory](#user-factual-memory)
    - [Environment Factual Memory](#environment-factual-memory)
  - [4.2 Experiential Memory](#42-experiential-memory)
    - [Case-based Memory](#case-based-memory)
    - [Strategy-based Memory](#strategy-based-memory)
    - [Skill-based Memory](#skill-based-memory)
    - [Hybrid Memory](#hybrid-memory)
  - [4.3 Working Memory](#43-working-memory)
    - [Single-turn Working Memory](#single-turn-working-memory)
    - [Multi-turn Working Memory](#multi-turn-working-memory)
- [5. Dynamics: How Memory Operates and Evolves?](#5-dynamics-how-memory-operates-and-evolves)
  - [5.1 Memory Formation](#51-memory-formation)
  - [5.2 Memory Evolution](#52-memory-evolution)
  - [5.3 Memory Retrieval](#53-memory-retrieval)
- [6. Resources and Frameworks](#6-resources-and-frameworks)
  - [6.1 Benchmarks](#61-benchmarks)
  - [6.2 Open-Source Frameworks](#62-open-source-frameworks)
- [7. Emerging Frontiers](#7-emerging-frontiers)
  - [7.1 Memory Retrieval vs. Memory Generation](#71-memory-retrieval-vs-memory-generation)
  - [7.2 Automated Memory Management](#72-automated-memory-management)
  - [7.3 Reinforcement Learning Meets Agent Memory](#73-reinforcement-learning-meets-agent-memory)
  - [7.4 Multimodal Memory](#74-multimodal-memory)
  - [7.5 Shared Memory in Multi-Agent Systems](#75-shared-memory-in-multi-agent-systems)
  - [7.6 Memory for World Model](#76-memory-for-world-model)
  - [7.7 Trustworthy Memory](#77-trustworthy-memory)
  - [7.8 Human-Cognitive Connections](#78-human-cognitive-connections)

---

## 1. Introduction & Background

Memory has emerged as a core capability of foundation model-based agents, underpinning long-horizon reasoning, continual adaptation, and effective interaction with complex environments. As LLMs evolve from static conditional generators into adaptive agents, memory transforms them from stateless text processors into entities capable of persistent, evolving cognition.

**Key Application Domains:**
- Personalized chatbots and emotional companions
- Recommender systems
- Social simulations
- Financial investigations and deep research
- Software engineering (SWE-bench)
- Scientific discovery

**The Core Problem:** Traditional taxonomies (long/short-term memory) have proven insufficient to capture the diversity and dynamics of contemporary agent memory systems. This survey proposes a unified framework organized by **Forms → Functions → Dynamics**.

---

## 2. What is Agent Memory?

### Formal Definition

An agent memory system is represented as an evolving memory state $M_t \in \mathcal{M}$, characterized by three lifecycle operators:

| Operator | Formula | Description |
|----------|---------|-------------|
| **Formation** | $M^{form}_{t+1} = F(M_t, \phi_t)$ | Transforms informational artifacts into memory candidates |
| **Evolution** | $M_{t+1} = E(M^{form}_{t+1})$ | Integrates new candidates: consolidation, conflict resolution, forgetting |
| **Retrieval** | $m_t = R(M_t, o_t, Q)$ | Returns context-dependent memory signal for the agent policy |

The agent policy is: $a_t = \pi_i(o_t, m_t, Q)$, where $m_t$ is the retrieved memory signal.

### 2.1 Agent Memory vs. LLM Memory

**Relationship:** Agent memory almost fully **subsumes** what was traditionally called "LLM memory."

| Overlap (Agent Memory) | Distinction (Pure LLM Memory) |
|------------------------|-------------------------------|
| Few-shot prompting as long-term memory | KV cache management |
| Self-reflection as short-term memory | Architectural modifications (RWKV, Mamba) |
| Context-window management for tasks | Attention-sparsity mechanisms |
| Cross-task persistence | Long-context processing architectures |

**Key Insight:** Works like MemoryBank and MemGPT, originally framed as "LLM memory," are naturally categorized as agent memory under modern definitions. True LLM memory focuses on intrinsic model dynamics (KV cache, architecture) without agentic behavior.

### 2.2 Agent Memory vs. RAG

| Dimension | RAG | Agent Memory |
|-----------|-----|--------------|
| **Knowledge Source** | Static, external databases | Dynamic, self-evolving |
| **Update Frequency** | Pre-indexed, rarely updated | Continuously updated via interaction |
| **Primary Goal** | Ground generation in facts | Maintain evolving cognitive state |
| **Task Domain** | HotpotQA, 2WikiMQA, MuSiQue | LoCoMo, GAIA, SWE-bench, StreamBench |
| **Memory Lifecycle** | Single inference task | Multi-turn, multi-task persistence |

**Blurring Boundaries:**
- **Modular RAG** (indexing, retrieval, reranking) → Appears in memory retrieval stage
- **Graph RAG** (knowledge graphs) → Shared structural backbone; only agent memory treats graphs as "living" representations
- **Agentic RAG** (autonomous retrieval) → Closest to agent memory, but still operates over external databases rather than internal persistent stores

### 2.3 Agent Memory vs. Context Engineering

| Aspect | Context Engineering | Agent Memory |
|--------|---------------------|--------------|
| **Paradigm** | Resource management | Cognitive modeling |
| **Scope** | Context window optimization | Persistent cognitive state |
| **Focus** | Syntactic validity, execution efficiency | What the agent knows, experienced, evolves |
| **Level** | Interface/resource allocation | Learning, adaptation, autonomy |

**Overlap:** Both share techniques for information compression, organization, and selection in long-horizon interactions (e.g., token pruning, rolling summaries).

**Distinction:** Context engineering constructs external scaffolding for perception/action under resource constraints. Agent memory constitutes the internal substrate for learning, adaptation, and identity continuity.

---

## 3. Form: What Carries Memory?

The survey identifies three dominant forms of agent memory based on **where memory resides and how it is represented**:

### 3.1 Token-level Memory

**Definition:** Memory stored as persistent, discrete, externally accessible units (text, visual tokens, audio frames). These units are transparent, editable, and interpretable.

**Classification by Topological Complexity:**

#### Flat Memory (1D)

**Definition:** Memories accumulated as sequences or bags of units without explicit inter-unit topology.

**Categories:**

| Sub-category | Description | Representative Works |
|--------------|-------------|---------------------|
| **Dialogue** | Store dialogue history, summaries, user profiles | MemGPT, MemoryBank, Mem0, RecursiveSum |
| **Preference** | Model user tastes, interests, decision patterns | RecMind, InteRecAgent, Memocrs |
| **Profile** | Maintain stable identity/character attributes | AI Persona, MPC, ChatHaruhi, RoleLLM |
| **Experience** | Archive trajectories, abstract insights | Reflexion, ExpeL, AWM, Voyager, ReasoningBank |
| **Multimodal** | Cross-modal discrete units | Ego-LLaVA, MovieChat, KARMA, Mem2Ego |

**Advantages:**
- ✅ Simplicity and scalability — minimal cost to append/prune
- ✅ Flexible retrieval via similarity search
- ✅ Transparent, easy to edit and interpret
- ✅ Plug-and-play integration with any LLM
- ✅ Long-term stability, avoids catastrophic forgetting

**Disadvantages:**
- ❌ Lack of explicit relational organization
- ❌ Redundancy and noise accumulate as memory grows
- ❌ Limited compositional reasoning and abstraction
- ❌ Retrieval quality heavily impacts coherence

#### Planar Memory (2D)

**Definition:** Single-layer structured organization — units related by graph, tree, table, or implicit connections within one plane.

**Sub-types:**

| Type | Description | Representative Works |
|------|-------------|---------------------|
| **Tree** | Hierarchical segmentation and aggregation | HAT, MemTree |
| **Graph** | Complex associations, causality, temporal dynamics | Ret-LLM, PREMem, A-Mem, COMET, M3-Agent, SALI |
| **Hybrid** | Segregate cognitive functions while sharing memory | Optimus-1, D-SMART |

**Advantages:**
- ✅ Explicit association mechanisms — leap from "storage" to "organization"
- ✅ Structured retrieval: key-value lookups, relational traversal
- ✅ Strong in storing, organizing, and managing memories

**Disadvantages:**
- ❌ All memories consolidated into single monolithic module
- ❌ High construction and search costs
- ❌ Inadequate for complex, diverse task scenarios

#### Hierarchical Memory (3D)

**Definition:** Multi-layer structured memory with inter-layer links, forming a volumetric/stratified space supporting vertical abstraction and cross-layer reasoning.

**Sub-types:**

| Type | Description | Representative Works |
|------|-------------|---------------------|
| **Pyramid** | Progressive abstraction, coarse-to-fine queries | HiAgent, GraphRAG, Zep, ILM-TR |
| **Multi-Layer** | Layered specialization by information type | Lyfe Agents, H-Mem, HippoRAG, AriGraph, SGMem, CAM |

**Advantages:**
- ✅ Multi-dimensional synergies across hierarchical and relational dimensions
- ✅ Complex multi-path queries across layers and abstraction levels
- ✅ High-precision retrieval, strong task performance
- ✅ Richer information with clearer, more explicit connections

**Disadvantages:**
- ❌ Structural complexity creates retrieval efficiency challenges
- ❌ Ensuring semantic meaningfulness is difficult
- ❌ Optimal 3D layout design remains an open problem

---

### 3.2 Parametric Memory

**Definition:** Memory stored within model parameters — information encoded through statistical patterns and accessed implicitly during forward computation.

#### Internal Parametric Memory

Memory encoded within the **original model parameters** (weights, biases).

| Injection Phase | Description | Representative Works |
|-----------------|-------------|---------------------|
| **Pre-Train** | Compress long-tail knowledge into parameters; optimize attention for long-context | LMLM, HierMemLM, StreamingLLM, TNL |
| **Mid-Train** | Integrate agent experience from downstream tasks | Agent-Founder, Early Experience |
| **Post-Train** | Adapt to personalized knowledge, edit facts | SELF-PARAM, Character-LM, MEND, APP, DINM |

**Advantages:**
- ✅ Simple structure, no extra inference overhead
- ✅ No additional deployment costs
- ✅ Implicit, abstract, and generalizable

**Disadvantages:**
- ❌ Difficult to update — requires retraining
- ❌ Costly and prone to catastrophic forgetting
- ❌ Better suited for domain knowledge than personalized memory

#### External Parametric Memory

Memory stored in **auxiliary parameter sets** without modifying original weights.

| Approach | Description | Representative Works |
|----------|-------------|---------------------|
| **Adapter-based** | Task-specific adapter modules (LoRA, MLP) | K-Adapter, WISE, ELDER, MemLoRA, MLP-Memory |
| **Auxiliary LM** | Separate model or external knowledge module | MAC, Retroformer |

**Advantages:**
- ✅ Balance between adaptability and model stability
- ✅ Modular updates, task-specific personalization
- ✅ Controlled rollback, avoids catastrophic forgetting
- ✅ Add/remove/replace without interfering with base model

**Disadvantages:**
- ❌ Influence is indirect, mediated through model's attention pathways
- ❌ Effectiveness depends on interface quality with internal knowledge

---

### 3.3 Latent Memory

**Definition:** Memory carried implicitly in internal representations (KV cache, activations, hidden states, embeddings) — not stored as explicit tokens or dedicated parameters.

**Advantages:** Avoids plaintext exposure, less inference latency, preserves fine-grained contextual signals.

#### Generate

Latent memory **produced by independent models/modules**, supplied as reusable internal representations.

| Modality | Description | Representative Works |
|----------|-------------|---------------------|
| **Single Modal** | Compress long sequences into latent tokens/vectors | Gist, SoftCoT, AutoCompressor, MemoRAG, MemoryLLM, M+, MemGen |
| **Multi Modal** | Encode images/audio/video as compact latents | CoMem, Time-VLM, MemoryVLA, XMem |

**Advantages:**
- ✅ Highly information-dense, task-tailored representations
- ✅ Avoids repeatedly processing full context
- ✅ Efficient reasoning across extended interactions

**Disadvantages:**
- ❌ Generation may introduce information loss or bias
- ❌ States can drift over multiple read-write cycles
- ❌ Additional computational overhead and data requirements

#### Reuse

**Direct reuse** of model's internal activations (primarily KV cache) as memory.

| Approach | Description | Representative Works |
|----------|-------------|---------------------|
| **KV Cache Storage** | Store past KV pairs, retrieve via KNN | Memorizing Transformers, FOT |
| **Residual Networks** | Lightweight SideNet treating KV as persistent store | LONGMEM, SirLLM, Memory3 |

**Advantages:**
- ✅ Full fidelity of internal activations — no information loss
- ✅ Conceptually simple, easy to integrate
- ✅ Highly faithful to model's original computation

**Disadvantages:**
- ❌ Raw KV caches grow rapidly with context length
- ❌ Increased memory consumption
- ❌ Effectiveness depends heavily on indexing strategies

#### Transform

**Modify, compress, or restructure** existing latent states rather than generating new ones.

| Approach | Description | Representative Works |
|----------|-------------|---------------------|
| **Token Pruning** | Keep only most influential tokens | Scissorhands, H2O |
| **KV Compression** | Aggregate, select, or budget KV pairs | SnapKV, PyramidKV, RazorAttention |
| **Reversible Compression** | Virtual memory tokens with reversible encoding | R3Mem |

**Advantages:**
- ✅ Compact, information-dense representations
- ✅ Reduced storage cost, efficient long-context retrieval
- ✅ Distilled semantic signals may be more useful than raw activations

**Disadvantages:**
- ❌ Risk of information loss during transformation
- ❌ Compressed states harder to interpret
- ❌ Additional computation for pruning/aggregation

---

### 3.4 Memory Form Adaptation Guide

| Memory Form | Key Features | Suitable Applications |
|-------------|--------------|----------------------|
| **Token-level** | Symbolic, addressable, transparent; fast CRUD operations | Multi-turn chatbots, personalized agents, recommenders, high-stake domains (law, finance, medical) |
| **Parametric** | Implicit, abstract, generalizable; slower updates; typically better performance gain | Role-playing, reasoning-intensive tasks, tasks requiring fundamentally new capabilities |
| **Latent** | Machine-native, token-efficient; convenient modality fusion; privacy-friendly | Multimodal memory, on-device/edge deployment, low-resource settings, encrypted domains |

---

## 4. Functions: Why Agents Need Memory?

The survey proposes a functional taxonomy organized into three primary pillars:

### 4.1 Factual Memory

**Answers: "What does the agent know?"**

The agent's declarative knowledge base, ensuring consistency, coherence, and adaptability by recalling explicit facts, user preferences, and environmental states.

**Cognitive Science Basis:** Mirrors human declarative memory:
- **Episodic Memory:** Personally experienced events (what, where, when)
- **Semantic Memory:** General factual knowledge independent of specific occasions

**Processing Pipeline:**
```
Raw Event Streams → Summarization/Reflection/Entity Extraction → Vector DB/KV Store/KG → Reusable Semantic Facts
```

**Three Fundamental Properties:**
- **Consistency:** Stable behavior and self-presentation over time
- **Coherence:** Robust context awareness, topical continuity
- **Adaptability:** Personalized behavior based on stored profiles

#### User Factual Memory

Facts sustaining human-agent interaction consistency.

| Sub-function | Description | Representative Works |
|--------------|-------------|---------------------|
| **Dialogue Coherence** | Preserve conversational context, user-specific facts, stable persona | MemGPT, MemoryBank, Think-in-Memory, RMM, COMEDY, Mem0 |
| **Goal Consistency** | Maintain explicit task representation, prevent intent drift | RecurrentGPT, Memolet, MemGuide, A-Mem, H-Mem |

**Key Techniques:**
- Heuristic selection and ranking (relevance, recency, importance, distinctiveness)
- Semantic abstraction (convert raw traces to thought representations)
- Structured organization (graph-based, hierarchical)

#### Environment Factual Memory

Facts sustaining consistency with the external world.

| Sub-function | Description | Representative Works |
|--------------|-------------|---------------------|
| **Knowledge Persistence** | Persistent world knowledge for long documents, QA, code | HippoRAG, MemTree, MemoryLLM, WISE, Zep, CAM |
| **Shared Access** | Common factual foundation for multi-agent collaboration | MetaGPT, GameGPT, G-Memory, Generative Agents, OASIS |

---

### 4.2 Experiential Memory

**Answers: "How does the agent improve?"**

Encapsulates procedural and strategic knowledge, accumulated to enable continual learning and self-evolution by abstracting from past trajectories, failures, and successes.

**Cognitive Science Basis:** Parallels human nondeclarative (procedural and habit) memory systems.

**Unique Capability:** Unlike biological systems, agents can introspect, edit, and reason over their own procedural knowledge.

#### Case-based Memory

Stores minimally processed records of historical episodes — prioritizes **high informational fidelity**.

| Type | Description | Representative Works |
|------|-------------|---------------------|
| **Trajectories** | Preserve interaction sequences for replay | Memento, JARVIS-1, Early Experience, MemGen |
| **Solutions** | Repository of proven solutions | ExpeL, Synapse, MapCoder, FinCon |

**Advantages:** High fidelity, verifiable evidence for imitation
**Disadvantages:** Retrieval efficiency challenges, context window consumption

#### Strategy-based Memory

Distills transferable reasoning patterns, workflows, and high-level insights.

| Granularity | Description | Representative Works |
|-------------|-------------|---------------------|
| **Insights** | Atomic knowledge: decision rules, reflective heuristics | H2R, R2D2, BrowserAgent, ToolMem, ReasoningBank |
| **Workflows** | Structured action sequences, executable routines | AWM, Agent KB |
| **Patterns** | Cognitive templates, problem-solving skeletons | Buffer of Thoughts, ReasoningBank, PRINCIPLES |

**Advantages:** Cross-task generalization, constrains search space, robust
**Disadvantages:** Structural guidelines, not executable actions — don't interact with environment directly

#### Skill-based Memory

Encapsulates executable procedural capacities — operationalizes abstract strategies into verifiable actions.

| Type | Description | Representative Works |
|------|-------------|---------------------|
| **Code Snippets** | Reusable executable programs | Voyager, Darwin Gödel Machine |
| **Functions/Scripts** | Modular behaviors | CREATOR, SkillWeaver, Memp, LEGOMem |
| **APIs** | Encapsulated skill interfaces | Gorilla, ToolLLM, COLT, DRAFT |
| **MCPs** | Open standard for tool discovery | Alita, Alita-G, MemTool |

**Advantages:** Callable, verifiable, composable executables
**Disadvantages:** Retrieval bottleneck with large tool repertoires, requires semantic understanding

#### Hybrid Memory

Integrates multiple forms to balance grounded evidence with generalizable logic.

| Approach | Description | Representative Works |
|----------|-------------|---------------------|
| **Case + Strategy** | Concrete trajectories + abstract heuristics | ExpeL, Agent KB, R2D2 |
| **Full Lifecycle** | Cases → Skills with dynamic transitions | G-Memory, Memp, ChemAgent |
| **Comprehensive** | Semantic + Episodic + Procedural | LARP, MemVerse |

---

### 4.3 Working Memory

**Answers: "What is the agent thinking about now?"**

A capacity-limited, dynamically controlled scratchpad for active context management during a single task or session. Transforms the context window from a passive buffer into a controllable, updatable workspace.

#### Single-turn Working Memory

Focuses on **input condensation and abstraction** within a single forward pass.

| Approach | Description | Representative Works |
|----------|-------------|---------------------|
| **Input Condensation** | Filter and compress massive inputs | LongLLMLingua, AutoCompressor, HyCo2 |
| **Observation Abstraction** | Abstract sensory observations | Synapse, Context-as-Memory, VideoAgent, M3-Agent |

#### Multi-turn Working Memory

Addresses **temporal state maintenance** across sequential interactions.

| Approach | Description | Representative Works |
|----------|-------------|---------------------|
| **State Consolidation** | Fold and consolidate intermediate artifacts | Context-folding, Agent-Fold, DeepAgent |
| **Hierarchical Folding** | Subgoal-centered hierarchical management | HiAgent, Mem1, IterResearch, ReSum |
| **Cognitive Planning** | Maintain goals, constraints, plans | PRIME, Agent-S, KARMA, SayPlan |

---

## 5. Dynamics: How Memory Operates and Evolves?

### 5.1 Memory Formation

How informational artifacts are transformed into memory candidates:

| Method | Description |
|--------|-------------|
| **Semantic Summarization** | Compress raw interactions into summaries |
| **Knowledge Distillation** | Extract reusable patterns from trajectories |
| **Structured Construction** | Build knowledge graphs, tables, tuples |
| **Latent Representation** | Encode as continuous embeddings |
| **Parametric Internalization** | Bake into model weights via fine-tuning |

### 5.2 Memory Evolution

How memory is updated over time:

| Operation | Description |
|-----------|-------------|
| **Consolidation** | Merge redundant entries, resolve conflicts |
| **Updating** | Incorporate new information, correct obsolete facts |
| **Forgetting** | Discard low-utility information, manage capacity |

### 5.3 Memory Retrieval

| Stage | Description |
|-------|-------------|
| **Retrieval Timing** | When to retrieve: task-initiation, intermittent, continuous |
| **Query Construction** | How to build retrieval queries |
| **Retrieval Strategies** | Vector search, graph traversal, hybrid methods |
| **Post-Retrieval** | Reranking, filtering, context assembly |

---

## 6. Resources and Frameworks

### 6.1 Benchmarks

| Category | Benchmarks |
|----------|-----------|
| **Memory/Lifelong Agents** | LoCoMo, LongMemEval, GAIA, XBench, BrowseComp, SWE-bench, StreamBench |
| **Related** | HotpotQA, 2WikiMQA, MuSiQue, Mind2Web, WebArena |

### 6.2 Open-Source Frameworks

| Framework | Focus |
|-----------|-------|
| **Mem0** | Standardized memory operations |
| **MemGPT** | OS-style hierarchical memory management |
| **Memary** | Vector search + semantic matching |
| **MemOS** | Memory operating system |
| **Zep** | Temporal Knowledge Graphs |
| **AriGraph** | Semantic + Episodic memory graph |

---

## 7. Emerging Frontiers

### 7.1 Memory Retrieval vs. Memory Generation

**Trend:** Shifting from retrieval-based memory (look up what was stored) to generation-based memory (actively produce new latent representations tailored to current needs).

**Future Direction:** Hybrid systems combining retrieval fidelity with generative flexibility; learned memory construction policies.

### 7.2 Automated Memory Management

**Trend:** From hand-crafted to automatically constructed memory systems.

**Future Direction:** Self-configuring memory architectures, adaptive memory sizing, automated forgetting policies, memory quality self-assessment.

### 7.3 Reinforcement Learning Meets Agent Memory

**Trend:** RL is internalizing memory management abilities for agents.

**Representative Works:** MemAgent, RMM, MemSearcher, MEM1, Mem-α, Memory-R1

**Future Direction:** RL-optimized memory formation/evolution/retrieval policies; memory-augmented reward shaping; end-to-end learnable memory controllers.

### 7.4 Multimodal Memory

**Current State:** Cross-modal discrete units and latent embeddings for vision-language-audio agents.

**Future Direction:** Unified multimodal latent spaces, cross-modal alignment, modality-adaptive memory compression.

### 7.5 Shared Memory in Multi-Agent Systems

**Trend:** From isolated memories to shared cognitive substrates.

**Future Direction:** Consensus protocols, conflict resolution in shared memory, privacy-preserving shared access, federated memory architectures.

### 7.6 Memory for World Model

**Concept:** Memory as the substrate for building internal world models that predict environment dynamics.

**Future Direction:** Memory-driven simulation, counterfactual reasoning, causal world modeling.

### 7.7 Trustworthy Memory

**Trend:** From trustworthy RAG to trustworthy memory.

**Challenges:** Memory verification, provenance tracking, hallucination resistance, bias detection, adversarial robustness.

### 7.8 Human-Cognitive Connections

**Basis:** Aligning agent memory architectures with human cognitive science (declarative/procedural memory, working memory models, forgetting curves).

**Future Direction:** Biologically-plausible memory dynamics, cognitive-inspired consolidation, metacognitive memory monitoring.

---

## Summary Comparison Matrix

| Dimension | Token-level | Parametric | Latent |
|-----------|------------|------------|--------|
| **Representation** | Explicit discrete units | Model weights | Hidden states/embeddings |
| **Accessibility** | Fully transparent | Implicit | Semi-implicit |
| **Update Speed** | Instant | Slow (requires training) | Fast (inference-time) |
| **Editability** | High | Low | Medium |
| **Interpretability** | High | Low | Low |
| **Storage Cost** | High (token budget) | Zero (in-model) | Medium (vector space) |
| **Catastrophic Forgetting** | None | Severe | Mild |
| **Cross-task Transfer** | Explicit retrieval | Implicit generalization | Representation reuse |
| **Best For** | Chatbots, recommenders, high-stake | Role-play, reasoning, domain experts | Multimodal, edge, privacy-sensitive |

| Function | Factual | Experiential | Working |
|----------|---------|-------------|---------|
| **Question** | What does the agent know? | How does the agent improve? | What is the agent thinking now? |
| **Temporal Scope** | Long-term | Long-term | Short-term (within-episode) |
| **Content** | Facts, preferences, states | Strategies, skills, cases | Active context, goals, plans |
| **Update Trigger** | New observations | Task completion/feedback | Every interaction turn |
| **Key Property** | Consistency, coherence | Generalization, adaptation | Efficiency, interference control |

---

*This document is a comprehensive summary extracted from the survey paper "Memory in the Age of AI Agents: A Survey — Forms, Functions and Dynamics" (arXiv:2512.13564v2, January 2026). For the complete analysis and full reference list, please refer to the original paper.*