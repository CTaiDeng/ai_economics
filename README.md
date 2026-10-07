# 市场参与的形式系统

## 原仓库与镜像声明

- 原仓库（GitHub）：[https://github.com/CTaiDeng/ai_economics](https://github.com/CTaiDeng/ai_economics)
- 镜像仓库（Gitee）：[https://gitee.com/qwe2018/ai_economics](https://gitee.com/qwe2018/ai_economics)

镜像仓库可能存在同步延迟或内容差异；如两者不一致，请以 GitHub 原仓库为准。

## 仓库目的

本仓库围绕后 AI 条件下的市场参与、价值形成与收入分配开展形式化经济研究，整理研究文稿及其配套参考资料。核心问题是：当部分产品的生产能力约束松弛、传统生产—就业—劳动收入—消费的传导减弱时，如何通过有效参与、贡献激励与底线保障，维持有真实资金来源、可持续且可核验的市场循环。

研究重点是“参与式分配、能者多得与坐标最小救济”的协同机制，并考察注意力与兴趣消费、组织合同、收益权与实际支付、治理公正和动态稳定之间的条件关系。文稿按明确的适用域、假设、证明和经验核验要求陈述结论。

## 个人思想与 AI 辅助表达声明

本仓库呈现作者 GaoZheng（高政）的个人思想与研究构想，文字表达借助 AI 生成、整理与润色，最终内容由作者审定并负责。

## 重点文献

**[《市场参与的形式系统：参与式分配、能者多得与最小救济的演化机制》](docs/tex/tex1/market_participation_formal_system.tex)**，Gao Zheng（高政）。

- [TeX 源文稿：docs/tex/tex1/market_participation_formal_system.tex](docs/tex/tex1/market_participation_formal_system.tex)
- [编译版 PDF](docs/tex/tex1/market_participation_formal_system.pdf)
- 主要内容：生产能力约束松弛与稀缺性转移；参与、注意力和消费回流；基本份额与贡献差异分配；最小救济、组织治理、动态稳定及可证伪预测。围棋行业作为组织参与的参照模型，市场循环的有向同伦表示作为条件性数学扩展。

本地配套文献统一存放在 [docs/project_docs/](docs/project_docs/)，包括纯粹数学、应用数学三卷及中文工作笔记。重点文献中的本地资料条目统一采用该目录下相对于仓库根目录的路径；对应的 Zenodo 来源、引用版本与本地文件见下文。

## 小说与思想实验：《百转千回》

《百转千回》以星原持续游戏世界中的参与、分配、治理与个人选择，展开本项目经济机制的叙事思想实验。

- 本地目录：[docs/book/book1/](docs/book/book1/)
- 本地阅读：[合订本](docs/book/book1/百转千回.md) · [分章目录](docs/book/book1/百转千回/)
- 配套说明：[星原世界设定](docs/book/book1/星原世界设定.md) · [章节题名考据](docs/book/book1/章节题名考据.md)
- 在线阅读：[起点中文网《动力涌现：城市的呼吸》章节入口](https://www.qidian.com/chapter/1046105982/924823718/)
- 版权与发布声明：[docs/book/NOTICE.md](docs/book/NOTICE.md)

版权与发布说明（适用于 `docs/book/`）：本目录小说为作者原创，著作权归作者所有。在发布平台上的使用依适用协议执行；本仓库由作者自行公开原稿。公开可读不等于授予第三方任意转载、改编或商业使用的许可。

名称与内容说明：起点中文网使用书名《动力涌现：城市的呼吸》，本仓库使用《百转千回》，两者对应同一作品；上述在线链接对应本地目录 `docs/book/book1/`。本地分章稿与合订本内容保持同步；在线发布稿与本地稿尚未完成全文逐章一致性核验，不能据此声明两个版本逐字一致。

## HTML 可视化页面

[docs/html/](docs/html/) 存放市场参与机制、小说思想实验及 G 框架配套资料的可视化图示，使用 HTML 与内嵌 SVG 展示机制循环、人物关系和理论架构。下载到本地后，可用浏览器直接打开对应的 `.html` 文件离线查看，无须启动服务器。

### AI 经济与小说图示：[docs/html/ai_economics/](docs/html/ai_economics/)

- [市场参与形式系统：闭环循环与三项核心功能](docs/html/ai_economics/market_participation_closed_cycle.html)：展示九步闭环、注意力与收入传导、参与式分配、贡献激励、坐标最小救济及治理实施链。
- [《百转千回》人物关系与情节架构图](docs/html/ai_economics/baizhuan_qianhui_characters_plot.html)：展示五组人物关系、四条叙事主线、十卷情节时间线及贯穿全书的经济机制。

### G 框架配套图示：[docs/html/G_Framework/](docs/html/G_Framework/)

- [GaoZheng G-Framework 分层架构图](docs/html/G_Framework/g_framework_architecture.html)：梳理 G 框架、G 代数及应用层的结构关系。
- [G-Framework 双轨架构：英文专著与中文率-商形式系统](docs/html/G_Framework/g_framework_dual_track.html)：对照英文专著与中文形式系统的组织结构及关联。
- [G-Framework 中文工作笔记综合：障碍谱系全景图](docs/html/G_Framework/obstruction_spectrum.html)：汇总障碍来源、阶数谱系及修复机制。
- [LHTS–TPH–G-HIT 统一泛化PDE求解替代方法论](docs/html/G_Framework/lhts_tph_ghit_methodology.html)：展示相关工作笔记中的方法结构、形式见证与衔接关系。

## 分析文章

[src/markdown/](src/markdown/) 存放围绕本项目研究文稿的 Markdown 分析文章，讨论问题诊断、机制建构、认识论价值及条件边界，并区分原文的形式结论、文章的理论评价与需要经验检验的判断。

**[市场参与的形式系统的问题发现与方案建构：认识论价值及其条件边界](src/markdown/1790969921625_市场参与的形式系统的问题发现与方案建构：认识论价值及其条件边界.md)**

- 主要内容：比较问题发现与方案建构的贡献，梳理产能与收入传导、注意力货币化与广泛收益、收益权与实际支付之间的区别，说明参与式分配、贡献激励、坐标最小救济及履约核验的条件。文章在明确的认识论尺度下评价问题发现的基础价值，并保留参数估计、因果识别、规模验证和外部有效性检验的要求。

## 脚本许可

标注 `SPDX-License-Identifier: MIT` 的脚本采用 MIT 许可，完整条款见 [LICENSES/MIT.txt](LICENSES/MIT.txt)。各脚本保留对应作者及版权年份；Git LFS 生成的钩子保留其原作者信息。

上述 MIT 许可仅适用于对应脚本，不扩展到研究文稿、小说或 Zenodo 来源资料。[docs/tex/LICENSE](docs/tex/LICENSE) 继续独立适用于 `docs/tex/` 中的文稿材料；小说文稿的版权与发布说明见 [docs/book/NOTICE.md](docs/book/NOTICE.md)，目录内的 MIT 工具脚本不受小说声明覆盖。其他文档按各自来源及许可声明处理。

## Zenodo 记录与引用

### 作者：GaoZheng（高政）

[作者博客](https://mymetamathematics.blogspot.com) · [![ORCID](https://orcid.org/sites/default/files/images/orcid_16x16.png) 0009-0008-3013-6626](https://orcid.org/0009-0008-3013-6626)

以下列出本项目参考资料对应的 Zenodo 来源与引用。引用条目采用所提供的发布版本信息，本地文档路径均相对于项目根目录。

### 纯粹数学

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.17651584.svg)](https://doi.org/10.5281/zenodo.17651584)

- 本地文档：[docs/project_docs/Pub_GFramework_PureMath.tex](docs/project_docs/Pub_GFramework_PureMath.tex)
- 来源：[Zenodo 记录 17651584](https://zenodo.org/records/17651584)
- 版本说明：下列引用为 v1.0；本地 TeX 文件的 `\date` 标注为 Version 1.1, 2025。

#### Citation

Gao, Z. (2025). Meta-Mathematical Theory based on Pan-Logic Analysis and Pan-Iterative Analysis (GaoZheng G-Framework) and the Principal-Bundle-Based Generalized Noncommutative Lie Algebra (GaoZheng G-Algebra). In Meta-Mathematical Theory based on Pan-Logic Analysis and Pan-Iterative Analysis (GaoZheng G-Framework) and the Principal-Bundle-Based Generalized Noncommutative Lie Algebra (GaoZheng G-Algebra): An Integrated Construction (v1.0). Zenodo. [https://doi.org/10.5281/zenodo.17651584](https://doi.org/10.5281/zenodo.17651584)

### 应用数学·第1卷

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.17686133.svg)](https://doi.org/10.5281/zenodo.17686133)

- 本地文档：[docs/project_docs/Pub_GFramework_AppMath_Vol1.tex](docs/project_docs/Pub_GFramework_AppMath_Vol1.tex)
- 来源：[Zenodo 记录 17686133](https://zenodo.org/records/17686133)
- 版本说明：下列引用为 v1.2；本地 TeX 文件的 `\date` 标注为 Version 1.3, 2025。

#### Citation

Gao, Z. (2025). GaoZheng G-Framework and GaoZheng G-Algebra: Applied Mathematics Volume I — Law-Space Geometry, GRL, Quantum Computing, and Superconductivity. In GaoZheng G-Framework and GaoZheng G-Algebra: Applied Mathematics Volume I — Law-Space Geometry, GRL, Quantum Computing, and Superconductivity (v1.2). Zenodo. [https://doi.org/10.5281/zenodo.17686133](https://doi.org/10.5281/zenodo.17686133)

### 应用数学·第2卷

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.17744672.svg)](https://doi.org/10.5281/zenodo.17744672)

- 本地文档：[docs/project_docs/Pub_GFramework_AppMath_Vol2.tex](docs/project_docs/Pub_GFramework_AppMath_Vol2.tex)
- 来源：[Zenodo 记录 17744672](https://zenodo.org/records/17744672)

#### Citation

Gao, Z. (2025). GaoZheng G-Framework and GaoZheng G-Algebra: Applied Mathematics Volume II – LBOPB, Life-Science Monoids, and Generative Precision Medicine. In GaoZheng G-Framework and GaoZheng G-Algebra: Applied Mathematics Volume II – LBOPB, Life-Science Monoids, and Generative Precision Medicine (v1.1). Zenodo. [https://doi.org/10.5281/zenodo.17744672](https://doi.org/10.5281/zenodo.17744672)

### 应用数学·第3卷

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.17762295.svg)](https://doi.org/10.5281/zenodo.17762295)

- 本地文档：[docs/project_docs/Pub_GFramework_AppMath_Vol3.tex](docs/project_docs/Pub_GFramework_AppMath_Vol3.tex)
- 来源：[Zenodo 记录 17762295](https://zenodo.org/records/17762295)

#### Citation

Gao, Z. (2025). GaoZheng G-Framework and GaoZheng G-Algebra: Applied Mathematics Volume III – HACA, PACER, and Certificate-Based AI. In GaoZheng G-Framework and GaoZheng G-Algebra: Applied Mathematics Volume III – HACA, PACER, and Certificate-Based AI (v1.0). Zenodo. [https://doi.org/10.5281/zenodo.17762295](https://doi.org/10.5281/zenodo.17762295)

### 中文工作笔记

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.22739417.svg)](https://doi.org/10.5281/zenodo.22739417)

- 本地目录：[docs/project_docs/notebook_tex_v5.2/](docs/project_docs/notebook_tex_v5.2/)
- 来源：[Zenodo 记录 22739417](https://zenodo.org/records/22739417)

#### Citation

Gao, Z. (2026). Meta-Mathematical Theory based on Pan-Logic Analysis and Pan-Iterative Analysis (GaoZheng G-Framework) and the Principal-Bundle-Based Generalized Noncommutative Lie Algebra (GaoZheng G-Algebra) 中文工作笔记 (Version v5.2). Zenodo. [https://doi.org/10.5281/zenodo.22739417](https://doi.org/10.5281/zenodo.22739417)
