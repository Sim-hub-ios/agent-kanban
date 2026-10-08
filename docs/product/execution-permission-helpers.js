/* Native permission fields for the HTML demonstration. Null means follow the executor, not a verified effective permission. */
(function (global) {
  'use strict';
  const option = (value, label, extra = {}) => ({ value, label, ...extra });
  const follow = () => option(null, '跟随执行器');
  const catalog = {
    codex: {
      name: 'Codex',
      fields: [
        { id: 'sandboxMode', label: '执行沙箱', native: 'sandbox / sandboxPolicy', options: [follow(), option('read-only', '只读沙箱'), option('workspace-write', '工作区写入'), option('danger-full-access', '完全访问（无沙箱）')] },
        { id: 'approvalPolicy', label: '审批策略', native: 'approvalPolicy', options: [follow(), option('on-request', '需要时请求审批'), option('never', '不请求审批（仍受沙箱约束）')] },
        { id: 'approvalsReviewer', label: '审批处理方', native: 'approvalsReviewer', options: [follow(), option('user', '用户审批'), option('auto_review', '自动评审')] }
      ],
      note: '沙箱限制可执行范围；审批策略与审批处理方分别控制审批。自动评审不会扩大沙箱范围。'
    },
    claude: {
      name: 'Claude',
      fields: [
        { id: 'sandbox.enabled', label: 'Shell 沙箱', native: 'sandbox.enabled', options: [follow(), option(true, '启用 Shell 沙箱'), option(false, '关闭 Shell 沙箱')] },
        { id: 'sandbox.autoAllowBashIfSandboxed', label: '沙箱内 Bash 审批', native: 'sandbox.autoAllowBashIfSandboxed', options: [follow(), option(false, '保留权限审批'), option(true, '沙箱内自动批准')] },
        { id: 'permissionMode', label: '权限模式', native: 'permissionMode', options: [follow(), option('default', 'Default · 标准权限检查'), option('acceptEdits', 'Accept edits · 自动允许文件编辑'), option('plan', 'Plan · 规划模式'), option('dontAsk', 'Don’t ask · 未获授权则拒绝'), option('bypassPermissions', 'Bypass permissions · 需执行器允许', { requiresNativeAuthorization: true }), option('auto', 'Auto · 自动权限评审', { requiresModelSupport: true })] }
      ],
      note: '启用时仅约束 Shell 及其子进程；不可用时停止，不允许沙箱外命令。权限模式仍受模型、账号和组织能力限制；Bypass 未确认授权时不可选。'
    },
    cursor: {
      name: 'Cursor',
      fields: [
        { id: 'sandbox.mode', label: '执行沙箱', native: 'sandbox.mode / --sandbox', options: [follow(), option('enabled', '启用沙箱'), option('disabled', '关闭沙箱')] },
        { id: 'approvalMode', label: '审批模式', native: 'approvalMode', options: [follow(), option('allowlist', 'Allowlist · 按允许 / 拒绝规则审批'), option('auto-review', 'Auto-review · 自动评审'), option('unrestricted', 'Unrestricted · 自动允许（拒绝规则优先）')] }
      ],
      note: '沙箱和审批是独立选项；当前 ACP 不提供这两项在线配置，正式接入需在下次启动时应用。'
    }
  };
  const defaults = {
    codex: { sandboxMode: null, approvalPolicy: null, approvalsReviewer: null },
    claude: { sandbox: { enabled: null, autoAllowBashIfSandboxed: null, failIfUnavailable: null, allowUnsandboxedCommands: null, excludedCommands: null }, permissionMode: null },
    cursor: { sandbox: { mode: null }, approvalMode: null }
  };
  const modes = [
    { id: 'request', name: '请求批准', icon: 'shield', description: '需要额外权限时，由你决定是否批准。' },
    { id: 'auto', name: '帮我批准', icon: 'agent', description: '由执行器自动评审权限请求。' },
    { id: 'full', name: '完全访问权限', icon: 'unlock', description: '关闭执行沙箱，允许更广泛的访问。' }
  ];
  const modeConfigs = {
    codex: {
      request: { sandboxMode: 'workspace-write', approvalPolicy: 'on-request', approvalsReviewer: 'user' },
      auto: { sandboxMode: 'workspace-write', approvalPolicy: 'on-request', approvalsReviewer: 'auto_review' },
      full: { sandboxMode: 'danger-full-access', approvalPolicy: 'never', approvalsReviewer: 'user' }
    },
    claude: {
      request: { sandbox: { enabled: true, autoAllowBashIfSandboxed: false }, permissionMode: 'default' },
      auto: { sandbox: { enabled: true, autoAllowBashIfSandboxed: false }, permissionMode: 'auto' },
      full: { sandbox: { enabled: false, autoAllowBashIfSandboxed: null }, permissionMode: 'bypassPermissions' }
    },
    cursor: {
      request: { sandbox: { mode: 'enabled' }, approvalMode: 'allowlist' },
      auto: { sandbox: { mode: 'enabled' }, approvalMode: 'auto-review' },
      full: { sandbox: { mode: 'disabled' }, approvalMode: 'unrestricted' }
    }
  };
  const clone = value => JSON.parse(JSON.stringify(value));
  const get = (value, path) => path.split('.').reduce((node, key) => node?.[key], value);
  function set(value, path, next) {
    const keys = path.split('.');
    const last = keys.pop();
    let node = value;
    for (const key of keys) node = node[key] ??= {};
    node[last] = next;
  }
  function optionAvailable(target, field, value) {
    if (target.executor === 'claude' && field === 'permissionMode' && value === 'bypassPermissions') return target.executionPermissionCapabilities?.claude?.bypassPermissions === true;
    if (target.executor === 'claude' && field === 'permissionMode' && value === 'auto') return target.modelId !== 'claude-haiku-4-5-20251001' && target.executionPermissionCapabilities?.claude?.auto !== false;
    return true;
  }
  function sanitize(executor, input, target) {
    const output = clone(defaults[executor]);
    for (const field of catalog[executor].fields) {
      const value = get(input, field.id);
      if (field.options.some(item => item.value === value) && optionAvailable(target, field.id, value)) set(output, field.id, value);
    }
    if (executor === 'claude') {
      if (output.sandbox.enabled === true) {
        output.sandbox.failIfUnavailable = true;
        output.sandbox.allowUnsandboxedCommands = false;
        output.sandbox.excludedCommands = [];
      } else output.sandbox.autoAllowBashIfSandboxed = null;
    }
    return output;
  }
  function normalize(target) {
    const executor = catalog[target.executor] ? target.executor : 'codex';
    if (!target.executionPermissionsByExecutor || typeof target.executionPermissionsByExecutor !== 'object' || Array.isArray(target.executionPermissionsByExecutor)) target.executionPermissionsByExecutor = {};
    const map = target.executionPermissionsByExecutor;
    const seed = Object.hasOwn(map, executor) ? map[executor] : target.permissionSnapshot?.executor === executor ? target.permissionSnapshot : null;
    map[executor] = sanitize(executor, seed, target);
    return target;
  }
  function current(target) {
    normalize(target);
    return target.executionPermissionsByExecutor[catalog[target.executor] ? target.executor : 'codex'];
  }
  function snapshot(target) {
    return { executor: catalog[target.executor] ? target.executor : 'codex', ...clone(current(target)), selectionSource: 'demo', resolved: null };
  }
  function change(target, fieldId, value) {
    const config = current(target);
    const field = catalog[target.executor]?.fields.find(item => item.id === fieldId);
    if (!field) return false;
    const parsed = value === '' || value === null ? null : value === 'true' ? true : value === 'false' ? false : value;
    if (!field.options.some(item => item.value === parsed) || !optionAvailable(target, fieldId, parsed)) return false;
    set(config, fieldId, parsed);
    normalize(target);
    return true;
  }
  function modeAvailability(target, modeId) {
    if (!modeConfigs[target.executor]?.[modeId]) return { available: false, reason: '此执行器暂不支持该模式' };
    if (target.executor === 'claude' && modeId === 'auto' && !optionAvailable(target, 'permissionMode', 'auto')) return { available: false, reason: target.modelId === 'claude-haiku-4-5-20251001' ? '当前 Haiku 模型不支持自动权限评审' : '执行器当前未开放自动权限评审' };
    if (target.executor === 'claude' && modeId === 'full' && !optionAvailable(target, 'permissionMode', 'bypassPermissions')) return { available: false, reason: '执行器尚未允许完全访问' };
    return { available: true, reason: '' };
  }
  function modeFor(target) {
    const config = current(target);
    return modes.find(mode => {
      const expected = modeConfigs[target.executor]?.[mode.id];
      return expected && catalog[target.executor].fields.every(field => get(config, field.id) === get(expected, field.id));
    })?.id || null;
  }
  function chooseMode(target, modeId) {
    normalize(target);
    if (!modeAvailability(target, modeId).available) return false;
    target.executionPermissionsByExecutor[target.executor] = sanitize(target.executor, modeConfigs[target.executor][modeId], target);
    return true;
  }
  function modeStatus(target) {
    if (modeFor(target)) return '';
    const config = current(target);
    const isDefault = catalog[target.executor].fields.every(field => get(config, field.id) === null);
    return isDefault ? '当前跟随执行器，实际权限未读取。' : '当前使用自定义权限；选择模式后替换。';
  }
  function modeDescription(target, modeId) {
    return ({
      codex: { request: '在工作区内执行，越界操作请求批准。', auto: '在沙箱内执行，由执行器评估审批请求。', full: '关闭执行沙箱，审批不再询问。' },
      claude: { request: 'Shell 在沙箱内运行，按权限规则请求批准。', auto: 'Shell 保留沙箱，由 Claude 评估审批请求。', full: '关闭 Shell 沙箱，使用已获准的完全访问权限。' },
      cursor: { request: '按执行器规则运行，需要授权时请求批准。', auto: '在沙箱内执行，自动评审需要授权的操作。', full: '关闭沙箱，拒绝规则仍然有效。' }
    })[target.executor]?.[modeId] || '';
  }
  function summary(target) {
    const modeId = modeFor(target);
    if (modeId) return modes.find(mode => mode.id === modeId).name;
    const config = current(target);
    return catalog[target.executor].fields.every(field => get(config, field.id) === null) ? '默认权限' : '自定义权限';
  }
  function describe(value) {
    if (!value || !catalog[value.executor]) return '未记录';
    const selected = catalog[value.executor].fields.map(field => {
      const chosen = get(value, field.id);
      const label = field.options.find(item => item.value === chosen)?.label;
      return chosen !== null && chosen !== undefined && label ? field.label + '：' + label : null;
    }).filter(Boolean);
    return selected.length ? selected.join('；') : '默认权限（跟随执行器，实际值未读取）';
  }
  global.ExecutionPermissions = Object.freeze({ catalog, modes, normalize, current, snapshot, change, summary, describe, optionAvailable, modeAvailability, modeFor, chooseMode, modeStatus, modeDescription, get });
})(typeof window !== 'undefined' ? window : globalThis);
