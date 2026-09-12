# TTS AI 额度弹窗设计 QA

**比较目标**

- 现状视觉真值：`/var/folders/50/cc35j9fx799chjjkky7z1sc00000gn/T/codex-clipboard-e48e40e2-5543-4955-98a5-50a40f4c864f.png`
- 玻璃与 Token 信息层级参考：`/var/folders/50/cc35j9fx799chjjkky7z1sc00000gn/T/codex-clipboard-56803d87-ac4e-476f-bcae-2932c1e9c74d.png`
- 最终概览截图：`/private/tmp/tts-quota-bars-light.png`
- 最终 Grok 详情截图：`/private/tmp/tts-quota-bars-detail.png`
- 深色截图：`/private/tmp/tts-quota-bars-dark.png`
- 降低透明度截图：`/private/tmp/tts-quota-bars-reduced.png`
- 全视图同屏比较：`/private/tmp/tts-design-qa-comparison.png`
- 详情同屏比较：`/private/tmp/tts-detail-qa-comparison.png`

**视口与归一化**

- 实现视口：420 × 540 pt；测试截图 420 × 540 px，density 1。
- 现状截图：1029 × 1630 px，约为 514.5 × 815 pt 的 @2x 菜单栏弹窗。
- 风格参考：741 × 547 px；它是不同产品的桌面截图，只作为玻璃层级和 Token 信息密度参考，不做逐像素复刻。
- 全视图比较把三张图等比缩放到 1080 px 高后水平拼接，没有裁切内容；比较重点是尺寸、密度、层级和表面处理。

**状态**

- 概览：五个服务商均有有效 fixture，Codex 与 GPT-5.3-Codex-Spark 独立额度均显示，所有主额度一次显示，无纵向滚动。
- 详情：Grok 共享周额度、Build/Chat 占用、今日/本周/本月切换和按需读取本地 Token 的初始状态。
- 额外状态：深色外观、降低透明度回退。

**Findings**

- 未发现剩余的 P0/P1/P2 视觉问题。
- 字体与排版：沿用 macOS 系统字体；标题、服务商、套餐、状态与数值形成五级层次。服务商名称在最终轮不再因套餐同排而截断；AntiGravity 最长指标按两列压缩，仍可辨认。
- 间距与布局：从 520 × 820 双列卡片改为 420 × 540 单列行，移除了原先的纵向空洞和主页面滚动；五家服务商、快捷操作与固定底栏均在首屏内。
- 颜色与视觉令牌：只使用一个根级 `NSVisualEffectView`，其上叠加白蓝半透明层和细描边；没有逐卡片模糊或重阴影。深色和降低透明度回退均保持可读对比。
- 额度进度：所有具备可比较上限的额度在数字下方显示紧凑余量条；正常为蓝色、低于 20% 为橙色、接近耗尽为红色。无上限基准的货币余额不伪造比例条。
- 图片与图标：最终 fixture 与发布包使用 Codex、Grok、DeepSeek、MiniMax、AntiGravity 的项目 SVG 资源，不再显示 SF Symbols 品牌替代图标；截图中没有压缩、裁切或透明边缘问题。
- 文案与内容：Grok 改为“共享额度”，并在详情中区分共享周额度和 Build/Chat 产品占用；Token 区明确“按需读取，不后台扫描”。
- 交互与无障碍：服务商整行可点击，详情与概览同尺寸；返回、刷新、设置、退出和快捷操作都有语义按钮及辅助标签；支持减少动态效果、减少透明度。

**Focused Region Evidence**

- 使用 `tts-detail-qa-comparison.png` 单独检查 Grok 额度进度、产品占用、周期分段控件和本地 Token 入口。文字、图标和按钮在 420 px 宽度下均未重叠或越界，因此不需要进一步裁切放大。

**Comparison History**

1. 初始现状存在 P1 密度与尺寸问题：520 × 820 双列卡片导致明显空白，且主额度需滚动。修复为 420 × 540 单列紧凑概览；后续截图确认五家额度全部在首屏。
2. 第一版紧凑 fixture 存在 P2 名称截断：套餐与服务商名称同排。修复为名称独占首行、状态与套餐置于次行；最终截图中 Grok 和 MiniMax 名称完整。
3. 第一版测试截图存在 P2 资源环境差异：测试包未解析发布包 SVG，显示了系统后备图标。增加测试资源目录注入后重新截图；最终图标与发布资源一致。
4. 详情 fixture 最初缺少宿主背景，造成黑底对比失真。修正测试宿主后重新截图；这不是发布 UI 缺陷，最终证据已使用白蓝背景。
5. 新增余量条与两条 Spark 指标后再次检查 420 × 540 视口；五家服务商、快捷操作和底栏仍完整同屏，浅色、深色和降低透明度状态均无裁切。

**Implementation Checklist**

- [x] 420 × 540 单列首屏展示五家额度。
- [x] 根级原生玻璃、深色和降低透明度回退。
- [x] 同尺寸服务商详情和按需 Token/缓存统计。
- [x] 官方品牌 SVG、快捷操作折叠和固定底栏。
- [x] Grok 共享额度真实 CLI 登录态验收。
- [x] Codex 普通额度、GPT-5.3-Codex-Spark 独立额度与彩色余量条。
- [x] 全量回归、视觉 fixture 和发布包构建。

**Follow-up Polish**

- P3：真实额度特别长时，AntiGravity 的第四个指标会使用最小缩放；后续可根据实际模型命名继续缩短指标别名，但当前没有截断核心数值。

final result: passed
