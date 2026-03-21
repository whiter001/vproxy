# vproxy

## 格式化

```bash
bash scripts/fmt.sh
```

## CI

Push 到 `main` 或创建 PR 时，GitHub Actions 会执行：

- V 代码格式检查
- 多平台编译检查
- `proxy/http/1/test_full.sh` 集成测试
