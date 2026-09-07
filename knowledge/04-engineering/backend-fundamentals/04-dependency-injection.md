---
title: 依赖注入
category: engineering
parent: 后端服务基础
level: 认知
updated: 2026-09-03
---

# 依赖注入

## 1. 概念定义

依赖注入（Dependency Injection, DI）是控制反转（Inversion of Control, IoC）的一种具体实现形态。

Spring 官方文档的定义：对象**仅通过**构造函数参数、工厂方法参数或实例属性来声明其协作对象，由容器在创建对象时实际注入这些依赖。这与对象自行 `new` 或通过服务定位器查找依赖的写法"根本相反"，故名控制反转。

.NET 官方文档更强调机制：依赖是"另一个对象所依赖的对象"，DI 通过三件事消除硬编码依赖——用接口或基类抽象依赖实现、在服务容器中注册依赖、将服务注入使用方的构造函数。

由此可提炼出 DI 的两个判别要件：**声明权归使用方，创建权归外部容器**。使用方不知道依赖的具体类型、创建时机与生命周期，这三点全部移交容器。

## 2. 三种注入方式

| 方式 | 机制 | 适用依赖 | 主要缺陷 |
|------|------|----------|----------|
| 构造注入 | 容器调用带参构造函数，参数即依赖 | 强制依赖 | 参数过多是坏味道，暗示职责过多 |
| Setter / 属性注入 | 容器先以无参构造实例化，再调用 setter | 可选依赖，且类内可给出合理默认值 | 对象可能在未完全初始化状态下被使用 |
| 接口注入 / 参数注入 | 依赖经由接口方法或函数形参传入 | 函数调用期依赖（如 Web 框架的处理器参数） | 依赖不随对象固化，无法表达长期持有关系 |

Spring 官方立场明确：**强制依赖用构造注入，可选依赖用 Setter 注入**，整体上提倡构造注入。理由是可将组件实现为不可变对象、保证必需依赖不为 `null`、组件返回给调用方时始终处于完全初始化状态。

## 3. 它解决什么问题

- **解耦**。使用方依赖抽象而非实现，替换实现无需修改使用方。
- **可测试性**。容器可整体替换为测试替身。FastAPI 提供 `app.dependency_overrides` 字典，以原依赖函数为键、覆盖函数为值，且覆盖对路径操作装饰器、`include_router` 等任意位置的依赖同样生效。
- **生命周期统一装配**。资源的创建与销毁由容器按作用域管理，而非散落在业务代码各处。.NET 文档明确：容器负责清理它所创建的类型并调用 `Dispose`；**从容器解析的服务绝不应由开发者释放**。
- **横切逻辑复用**。鉴权、配额、追踪等以依赖声明，避免逐处重复。

## 4. 各框架的实现形态对比

| 框架 | 注入载体 | 装配时机 | 作用域粒度 | 覆盖手段 |
|------|----------|----------|-----------|----------|
| FastAPI | `Depends(callable)` | 每请求解析，构建依赖树 | 请求级（默认）；`yield` 依赖支持 `function` / `request` | `app.dependency_overrides` |
| Spring | IoC 容器管理 bean | 容器刷新时预实例化单例 | singleton、prototype、request、session、application、websocket | `@Profile`、`@Primary` |
| .NET | `IServiceCollection` 注册 + 构造注入 | `BuildServiceProvider` 后按需解析 | Transient、Scoped、Singleton，支持 Keyed services | 重新注册实现类型 |
| Angular | `inject()` 于注入上下文中调用 | 组件/服务构造期 | 分层注入器：root 单例，组件级可再提供 | 在组件 `providers` 中重新提供 |

### 4.1 FastAPI 形态的两点特殊之处

**其一，它没有进程级容器。** 依赖是"每请求一次调用"的可调用对象，因此长生命周期资源（连接池、模型）必须放在 `lifespan` 或模块级变量中，不能指望 `Depends` 复用。这是从 Spring 转过来的开发者最容易踩的坑。

**其二，`Depends` 的 `use_cache` 默认为 `True`。** 同一请求内该依赖被多次声明时仅调用一次并复用返回值，这是"请求内单例"语义，与 Spring 的容器级 singleton 不是一回事。设为 `False` 可强制每次重新调用。

### 4.2 yield 依赖

`yield` 依赖是 FastAPI 对生命周期闭环的补齐：`yield` 之前为建立、之后为清理，内部由上下文管理器实现。

作用域的差别很关键：

- 默认 `scope="request"`，清理在响应发送给客户端之后执行。
- 若资源在路由函数返回后即不再需要，可用 `Depends(..., scope="function")` 让清理提前到响应发送之前。

约束：`scope="request"` 的依赖，其子依赖也必须是 `request`；`scope="function"` 的依赖则可以同时拥有 `function` 与 `request` 子依赖。

## 5. 作用域与生命周期陷阱

| 作用域 | 语义 | 典型对象 | 陷阱 |
|--------|------|----------|------|
| Singleton / 进程级 | 每容器（或每进程）一份 | 连接池、LLM 客户端、配置 | 必须线程安全；持有请求级状态会造成串号 |
| Request / Scoped | 每请求一份 | 数据库会话、事务 | 被单例捕获后被"提升"为单例 |
| Transient / Prototype | 每次解析新建 | 轻量无状态对象 | 容器会持有 `IDisposable` 实例引用，从根容器解析会致内存泄漏 |

### 5.1 俘虏依赖（Captive Dependency）

.NET 文档把"长生命周期服务持有短生命周期服务"命名为 **Captive Dependency**，并给出检测手段：以 `validateScopes: true` 构建 `ServiceProvider`，会抛出 `Cannot consume scoped service 'Bar' from singleton 'Foo'.`；在 `CreateApplicationBuilder` 的开发环境下默认开启该校验。

Spring 的对应问题是"singleton 依赖 prototype"：依赖在实例化时解析一次，注入给单例的 prototype 实例是唯一的那一个。若需运行时反复取新实例，必须用方法注入，或用 `ObjectFactory` / `ObjectProvider` / JSR-330 `Provider` 按需获取，也可注入 AOP 作用域代理。

## 6. 常见误用

- **过度注入**。单个类注入依赖过多通常意味着违反单一职责，应拆分而非继续注入。.NET 文档将此列为显式反模式。
- **循环依赖**。Spring 文档指出，以构造注入为主时可能出现无法解析的循环依赖，容器抛出 `BeanCurrentlyInCreationException`；官方给出的解法是改为 Setter 注入，但同时声明"尽管不推荐"。更根本的处理是拆分公共逻辑，打破依赖环。
- **在单例中持有请求级状态**。与俘虏依赖同源，表现为跨请求数据污染，在并发下不可复现——这是最难排查的一类 bug。
- **服务定位器与静态访问**。`GetService` 取依赖、把 `IApplicationBuilder.ApplicationServices` 存为静态字段，二者都绕开了 IoC，属于 DI 的反模式。
- **在 DI 工厂中写异步阻塞代码**。.NET 文档明确不支持基于 `async/await` 的异步解析，异步 DI 工厂中使用 `Task.Result` 会导致死锁，DI 工厂应保持快速且同步。

## 7. AI Agent 服务的注意点

### 7.1 注入对象与建议作用域

| 对象 | 建议作用域 | 理由 |
|------|-----------|------|
| 数据库连接池 | 进程级 | 创建昂贵、非线程独占；会话才是请求级 |
| Redis 客户端 | 进程级 | 内部已维护连接池 |
| LLM / Embedding 客户端 | 进程级 | 携带连接与限流状态，宜在 `lifespan` 建立、关闭 |
| 向量库客户端 | 进程级 | 同上 |
| 配置（Settings） | 进程级 | 常配合 `lru_cache` 实现单次读取；仍通过 `Depends` 注入以便测试覆盖 |
| 追踪器 / Tracer | 进程级 provider + 请求级 span | provider 复用，span 必须每请求新建 |
| 数据库会话 / 事务 | 请求级 | 用 `yield` 依赖保证归还 |
| 工具执行器、沙箱会话 | 请求级或会话级 | 持有用户态状态，不可跨请求复用 |

### 7.2 三条硬性约束

**第一，上下文传递不能污染实例。** LLM 客户端本身是单例，但每次调用的 `trace_id`、`user_id` 必须经参数或 `contextvars` 传递，绝不可写入客户端实例属性。这是 Agent 服务中最典型的数据串号来源。

**第二，`lifespan` 中建立的资源是每 worker 进程一份。** 多 worker 下进程级单例的个数等于 worker 数，任何"全局计数""本地缓存"都必须外置到 Redis。详见 [[06-concurrency-models]]。

**第三，本地推理场景下常驻的模型权重应按进程级持有并复用。** 其内存占用随 worker 数线性增长，须与 worker 数一并规划。

## 8. 自测问题

1. 依赖注入与控制反转是什么关系？
2. 构造注入与 Setter 注入各自的适用场景，官方推荐哪一种，理由是什么？
3. FastAPI 的 `Depends` 与 Spring 的 IoC 容器在"单例"语义上有何本质差别？
4. 什么是俘虏依赖？如何检测？在并发下的表现是什么？
5. `yield` 依赖的 `scope="function"` 与 `scope="request"` 差在哪里？
6. 在 Agent 服务中，为什么 LLM 客户端不能把 `user_id` 存为实例属性？

## 9. 参考来源

1. FastAPI — Dependencies，https://fastapi.tiangolo.com/tutorial/dependencies/
2. FastAPI — Dependencies with yield，https://fastapi.tiangolo.com/tutorial/dependencies/dependencies-with-yield/
3. FastAPI — Depends() and Security() API 参考，https://fastapi.tiangolo.com/reference/dependencies
4. FastAPI — Testing Dependencies with Overrides，https://fastapi.tiangolo.com/advanced/testing-dependencies/
5. Spring Framework — Dependency Injection，https://docs.spring.io/spring-framework/reference/core/beans/dependencies/factory-collaborators.html
6. Spring Framework — Bean Scopes，https://docs.spring.io/spring-framework/reference/core/beans/factory-scopes.html
7. Microsoft Learn — Dependency injection in .NET，https://learn.microsoft.com/en-us/dotnet/core/extensions/dependency-injection
8. Microsoft Learn — Dependency injection guidelines，https://learn.microsoft.com/en-us/dotnet/core/extensions/dependency-injection-guidelines
9. Angular — Dependency injection，https://angular.dev/guide/di
10. Martin Fowler — Inversion of Control Containers and the Dependency Injection pattern，https://martinfowler.com/articles/injection.html
