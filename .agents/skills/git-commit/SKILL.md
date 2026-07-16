---
name: git-commit
description: Use when the user requests to commit changes, git commit, stage files, or asks "提交一下", "git 提交", "git提交一下", running formatting checks, generating standard commit messages, and committing changes in this repository (analysis and tests are already performed during the modification phase, so they are skipped here).
---

# Git Commit Skill

This skill guides the process of checking, formatting, and committing changes to Git in this repository.

## Step-by-Step Commit Workflow

> [!NOTE]
> Since code modifications must already be verified via `flutter analyze` and `flutter test` during the editing phase, those validation checks are skipped during the commit phase to save time.


### 1. Inspect Status and Diff
Before staging any files, check the current workspace state to understand what files are modified or untracked:
```powershell
git status
```
For targeted inspection of specific file changes:
```powershell
git diff <file-path>
```

### 2. Format Checks
Before committing, ensure the modified code adheres to project formatting:
- **Formatting Dart Files**:
  ```powershell
  dart format lib test
  ```

### 3. Stage Files
Stage only the files relevant to the current task or logical unit:
```powershell
git add <file-path1> <file-path2>
```
Avoid using `git add .` or `git add -A` if there are unrelated dirty files in the git tree that the user is actively working on.

### 4. Create Commit Message
Follow these project naming conventions:
- Commit messages should be short and direct.
- Subjects can be in English or Chinese (e.g. `add log`, `update`, `font config`, `fix connection timeout`).
- Keep the commit scoped and in the imperative mood.

### 5. Execute Commit
Commit the staged changes:
```powershell
git commit -m "<message>"
```

### 6. Verify Post-Commit State
Ensure the commit succeeded and the working directory is in the expected state:
```powershell
git status
```
