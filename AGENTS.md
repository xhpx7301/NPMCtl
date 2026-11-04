# 项目协作约定

- 用户要求：本项目当前和后续修改完成后，运行相关验证，提交并推送到 GitHub 的 `main` 主分支。需要经 PR 合并时完成合并；主分支允许直接推送时直接提交即可。
- 提交前检查远端更新，保留已有修改，不强制推送、不覆盖其他人的提交。
- NPMCtl 通过单文件安装器分发 `npmctl.sh`，运行时资源需由脚本生成，不能依赖用户另外下载仓库文件。
- 修改 Bash 脚本至少运行 `bash -n`；443 复用改动运行 `python3 -m unittest discover -s tests -v`，能使用 Docker 时另外运行 `python3 tests/integration_l4.py`。
