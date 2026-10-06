# MaaNTE 深度技术文档 — 扩展篇

> 本文档指导如何为 MaaNTE 添加新功能，包括 CustomAction、Pipeline 节点、任务配置等。

> 【2026-09-19 现状标注】扩展操作针对本地 `MaaNTE/` 框架本体（仍保留）。项目侧现状：Maa 只做工具、不整体接管；新增模板/ROI 需求走实机采集（`data/mac_shots/` 现有 208 张 9/18 批次）+ `tools/maa_node_audit.py` 判定闭环，剩余 24 个缺模板节点清单见 `docs/文档库/探索文档/界面采集作业指令.md`（⚠️ 2026-09-29 路径订正：原记路径不存在，实际多两级）；上游 PR（如 BidKing PR#434）按"独立文件夹"方式管理（现 `BidKing_PR434/`，git 7b7d2db，未合并）。

---

## 目录

1. [新增 CustomAction](#1-新增-customaction)
2. [新增 Pipeline 节点](#2-新增-pipeline-节点)
3. [新增任务配置](#3-新增任务配置)
4. [新增识别模板](#4-新增识别模板)
5. [新增场景处理](#5-新增场景处理)
6. [调试技巧](#6-调试技巧)
7. [常见问题](#7-常见问题)

---

## 1. 新增 CustomAction

### 1.1 完整流程

#### 步骤 1：创建 Python 文件

```python
# agent/custom/action/MyFeature/my_action.py
from __future__ import annotations

import json
from pathlib import Path

from maa.agent.agent_server import AgentServer
from maa.custom_action import CustomAction
from maa.context import Context

from ..Common.logger import get_logger
from ..Common.utils import get_image
from utils.maafocus import PrintT

logger = get_logger(__name__)


@AgentServer.custom_action("my_feature_action")
class MyFeatureAction(CustomAction):
    """我的功能描述"""

    def run(self, context: Context, argv: CustomAction.RunArg) -> CustomAction.RunResult:
        controller = context.tasker.controller
        
        # 解析参数
        params = {}
        if argv.custom_action_param:
            try:
                params = json.loads(argv.custom_action_param) if isinstance(argv.custom_action_param, str) else argv.custom_action_param
            except Exception as e:
                logger.warning("Failed to parse params: %s", e)

        # 主逻辑
        try:
            # 获取截图
            img = get_image(controller)
            
            # 自定义处理...
            
            PrintT(context, "my_feature.started")
            return CustomAction.RunResult(success=True)
        except Exception as e:
            logger.error("MyFeatureAction failed: %s", e)
            return CustomAction.RunResult(success=False)
```

#### 步骤 2：注册到 __init__.py

```python
# agent/custom/action/__init__.py

# 添加导入
from .MyFeature.my_action import *

# 添加到 __all__
__all__ = [
    # ... 现有条目 ...
    "MyFeatureAction",
]
```

#### 步骤 3：创建 Pipeline JSON

```json
{
  "name": "MyFeatureNode",
  "recognition": {
    "type": "TemplateMatch",
    "param": {
      "template": ["MyFeature/Target.png"],
      "roi": [100, 100, 200, 100],
      "threshold": [0.8]
    }
  },
  "action": {
    "type": "Custom",
    "param": {
      "custom_action_name": "my_feature_action",
      "custom_action_param": {
        "mode": "auto"
      }
    }
  },
  "next": ["MyFeatureNextNode", "__JumpBackSceneAnyEnterWorld"]
}
```

#### 步骤 4：创建任务配置

```json
{
  "task": [
    {
      "name": "MyFeature",
      "label": "$task_my_feature_label",
      "entry": "MyFeatureEntrance",
      "description": "$task_my_feature_desc",
      "option": ["MyFeatureMode"],
      "group": ["Custom"]
    }
  ],
  "option": {
    "MyFeatureMode": {
      "type": "select",
      "label": "$task_my_feature_option_mode",
      "default_case": "ModeAuto",
      "cases": [
        {
          "name": "ModeAuto",
          "label": "自动模式",
          "pipeline_override": {
            "MyFeatureNode": {
              "action": {
                "param": {
                  "custom_action_param": {"mode": "auto"}
                }
              }
            }
          }
        },
        {
          "name": "ModeManual",
          "label": "手动模式",
          "pipeline_override": {
            "MyFeatureNode": {
              "action": {
                "param": {
                  "custom_action_param": {"mode": "manual"}
                }
              }
            }
          }
        }
      ]
    }
  }
}
```

#### 步骤 5：更新 interface.json

```json
{
  "import": [
    // ... 现有条目 ...
    "resource/tasks/MyFeature.json"
  ]
}
```

#### 步骤 6：更新本地化

```json
{
  "task_my_feature_label": "我的功能",
  "task_my_feature_desc": "描述文本",
  "task_my_feature_option_mode": "运行模式",
  "my_feature_started": "开始执行",
  "my_feature_done": "执行完成"
}
```

同步更新其他 4 个语言文件。

---

## 2. 新增 Pipeline 节点

### 2.1 节点命名规范

- **公开节点**：帕斯卡命名，带模块前缀（如 `FishNewEntrance`）
- **私有节点**：`__` 前缀（如 `__ScenePrivateCloseDialog`）
- **跳转节点**：`[JumpBack]NodeName` 格式

### 2.2 标准节点模板

```json
{
  "name": "NodeName",
  "recognition": {
    "type": "TemplateMatch",
    "param": {
      "template": ["path/to/template.png"],
      "roi": [x, y, w, h],
      "threshold": [0.8]
    }
  },
  "action": {
    "type": "Click",
    "param": {
      "target": [x, y]
    }
  },
  "next": ["NextNode1", "NextNode2"]
}
```

### 2.3 复合节点

```json
{
  "name": "AndNode",
  "recognition": {
    "type": "And",
    "param": {
      "children": [
        {"name": "Child1"},
        {"name": "Child2"}
      ]
    }
  },
  "action": {
    "type": "DoNothing"
  },
  "next": ["SuccessNode"]
}
```

### 2.4 等待节点

```json
{
  "name": "WaitForLoading",
  "recognition": {
    "type": "TemplateMatch",
    "param": {
      "template": ["Common/Loading.png"],
      "threshold": [0.9]
    }
  },
  "action": {
    "type": "DoNothing"
  },
  "pre_wait_freezes": {
    "times": 3,
    "interval": 1.0
  },
  "next": ["AfterLoading"]
}
```

---

## 3. 新增任务配置

### 3.1 选项类型详解

#### Switch 选项

```json
{
  "MySwitch": {
    "type": "switch",
    "label": "$key_label",
    "description": "$key_desc",
    "default_case": "No",
    "cases": [
      {
        "name": "Yes",
        "label": "$option_switch_case_yes",
        "pipeline_override": {
          "NodeName": {"enabled": true}
        }
      },
      {
        "name": "No",
        "label": "$option_switch_case_no",
        "pipeline_override": {
          "NodeName": {"enabled": false}
        }
      }
    ]
  }
}
```

#### Input 选项

```json
{
  "MyInput": {
    "type": "input",
    "label": "$key_label",
    "inputs": [
      {
        "name": "value",
        "label": "$key_label",
        "default": "10",
        "pipeline_type": "int",
        "verify": "^\\d+$"
      }
    ],
    "pipeline_override": {
      "NodeName": {
        "action": {
          "param": {
            "custom_action_param": {"count": "{value}"}
          }
        }
      }
    }
  }
}
```

#### Select 选项

```json
{
  "MySelect": {
    "type": "select",
    "label": "$key_label",
    "default_case": "Case1",
    "cases": [
      {
        "name": "Case1",
        "label": "$case1_label",
        "pipeline_override": {
          "NodeName": {
            "action": {
              "param": {"mode": "case1"}
            }
          }
        }
      },
      {
        "name": "Case2",
        "label": "$case2_label",
        "pipeline_override": {
          "NodeName": {
            "action": {
              "param": {"mode": "case2"}
            }
          }
        }
      }
    ]
  }
}
```

### 3.2 控制器限制

```json
{
  "task": [
    {
      "name": "MyTask",
      "controller": ["Win32-Front"],
      "entry": "MyTaskEntrance"
    }
  ]
}
```

---

## 4. 新增识别模板

### 4.1 截图规范

- 分辨率：1280×720
- 格式：PNG（无损）或 JPG（高质量）
- 命名：`模块名/功能描述.png`

### 4.2 模板组织

```
assets/resource/base/image/
├── Common/
│   ├── Button/
│   │   ├── InWorld/
│   │   │   ├── Chat.png
│   │   │   ├── BagButton.png
│   │   │   └── ...
│   │   └── ListButton.png
│   └── Loading.png
├── Fish/
│   ├── slider.png
│   ├── valid_region_left.png
│   ├── valid_region_right.png
│   └── ...
├── MyFeature/
│   └── target.png
└── ...
```

### 4.3 模板质量要求

1. **尺寸适中**：建议 30×30 到 200×200 像素
2. **特征明显**：包含足够的视觉特征
3. **背景干净**：尽量避免复杂背景
4. **颜色准确**：使用游戏内实际颜色

---

## 5. 新增场景处理

### 5.1 场景识别

在 `SceneManager/` 目录下创建场景处理节点：

```json
{
  "name": "SceneMyFeature",
  "recognition": {
    "type": "TemplateMatch",
    "param": {
      "template": ["MyFeature/SceneBg.png"],
      "threshold": [0.7]
    }
  },
  "action": {
    "type": "DoNothing"
  },
  "next": ["MyFeatureEntrance"]
}
```

### 5.2 弹窗处理

```json
{
  "name": "__MyFeatureDialogClose",
  "recognition": {
    "type": "TemplateMatch",
    "param": {
      "template": ["Common/Button/WhiteButton.png"],
      "roi": [600, 400, 80, 40],
      "threshold": [0.8]
    }
  },
  "action": {
    "type": "Click",
    "param": {
      "target": [640, 420]
    }
  },
  "next": ["__JumpBackSceneAnyEnterWorld"]
}
```

---

## 6. 调试技巧

### 6.1 启用调试模式

```python
# 在 CustomAction 中
debug = True
navigator = WaypointNavigator(context, debug=debug)
```

### 6.2 使用 Debug Windows

```python
# MapLocator 调试
locator = MapLocator(debug=True)
locator.show_debug(template, result)

# AnglePredictor 调试
predictor = AnglePredictor(debug=True)
predictor.show_debug(img_crop, result)
```

### 6.3 日志级别

```python
# main.py 中
from utils.logger import change_console_level
change_console_level("DEBUG")
```

### 6.4 单节点测试

在 VS Code 中使用 "Maa Pipeline Support" 插件：
1. 右键 Pipeline JSON 中的节点
2. 选择 "Run Single Node"
3. 查看识别结果和执行效果

---

## 7. 常见问题

### 7.1 CustomAction 未注册

**症状**：运行时报 `Unknown custom action`

**解决**：
1. 检查 `__init__.py` 中的 import
2. 检查 `__all__` 列表
3. 确认装饰器名称与 Pipeline 中一致

### 7.2 模板匹配失败

**症状**：识别命中率低

**解决**：
1. 检查 ROI 是否正确
2. 调整 threshold
3. 重新截取模板
4. 考虑使用 OCR 替代

### 7.3 坐标偏移

**症状**：点击位置不准

**解决**：
1. 确认游戏分辨率是 1280×720
2. 检查 `screen.map_rect()` 调用
3. 验证模板坐标是否基于 1280×720

### 7.4 任务卡住

**症状**：Pipeline 不前进

**解决**：
1. 检查 next 列表是否覆盖所有状态
2. 添加 `[JumpBack]SceneAnyEnterWorld` 处理异常
3. 检查是否有遗漏的弹窗处理

---

## 8. 最佳实践

### 8.1 代码组织

```
agent/custom/action/
├── MyFeature/
│   ├── __init__.py
│   ├── action.py          # 主动作
│   ├── helper.py          # 辅助函数
│   └── utils.py           # 工具函数
```

### 8.2 错误处理

```python
try:
    # 主逻辑
    result = do_something()
    return CustomAction.RunResult(success=result)
except Exception as e:
    logger.error("Unexpected error: %s", e, exc_info=True)
    return CustomAction.RunResult(success=False)
```

### 8.3 资源清理

```python
def run(self, context, argv):
    resource = None
    try:
        resource = acquire_resource()
        # 使用资源
        return CustomAction.RunResult(success=True)
    finally:
        if resource:
            resource.close()
```

### 8.4 性能优化

1. **避免重复截图**：缓存 `controller.cached_image`
2. **减少模板数量**：只保留必要的模板
3. **使用 ROI**：缩小搜索范围
4. **合理设置阈值**：避免过高或过低

---

*文档版本：v1.0 | 最后更新：2026-09-13（原文误写 2025）；2026-09-19 加现状标注*
