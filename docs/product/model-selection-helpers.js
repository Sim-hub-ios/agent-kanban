/* Offline picker snapshot checked 2026-10-07; model requests remain simulated.
 * Codex: current local catalog cache. Claude: official public catalog. Cursor: CLI catalog subset.
 * Cursor base picker keys group returned variants; variantIds are recorded CLI values, never sent here. */
(function (global) {
  'use strict';
  const catalog = {
    "codex": [
      {
        "id": "gpt-6.1-sol",
        "name": "GPT-6.1-Sol",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max",
          "ultra"
        ],
        "defaultEffort": "low"
      },
      {
        "id": "gpt-6-astra",
        "name": "GPT-6-Astra",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max",
          "ultra"
        ],
        "defaultEffort": "medium"
      },
      {
        "id": "gpt-6-sol",
        "name": "GPT-6-Sol",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max",
          "ultra"
        ],
        "defaultEffort": "medium"
      },
      {
        "id": "gpt-6-luna",
        "name": "GPT-6-Luna",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max"
        ],
        "defaultEffort": "medium"
      },
      {
        "id": "gpt-5.6-sol",
        "name": "GPT-5.6-Sol",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max",
          "ultra"
        ],
        "defaultEffort": "low"
      },
      {
        "id": "gpt-5.6-terra",
        "name": "GPT-5.6-Terra",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max",
          "ultra"
        ],
        "defaultEffort": "medium"
      },
      {
        "id": "gpt-5.6-luna",
        "name": "GPT-5.6-Luna",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max"
        ],
        "defaultEffort": "medium"
      }
    ],
    "claude": [
      {
        "id": "claude-sonnet-5-5",
        "name": "Sonnet 5.5",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max"
        ]
      },
      {
        "id": "claude-opus-5-5",
        "name": "Opus 5.5",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max"
        ]
      },
      {
        "id": "claude-fable-5-1",
        "name": "Fable 5.1",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh",
          "max"
        ]
      },
      {
        "id": "claude-haiku-4-5-20251001",
        "name": "Haiku 4.5",
        "efforts": [],
        "unavailable": "Haiku 4.5 不支持独立推理强度。"
      }
    ],
    "cursor": [
      {
        "id": "auto",
        "name": "Auto",
        "efforts": [],
        "unavailable": "Auto 自动选择模型，没有固定模型版本或独立强度。"
      },
      {
        "id": "cursor-grok-4.7",
        "name": "Grok 4.7",
        "efforts": [
          "low",
          "medium",
          "high",
          "xhigh"
        ],
        "variantIds": {
          "low": "grok-4.7-low",
          "medium": "grok-4.7-medium",
          "high": "grok-4.7-high",
          "xhigh": "grok-4.7-xhigh"
        }
      },
      {
        "id": "composer-2.5",
        "name": "Composer 2.5",
        "efforts": [],
        "unavailable": "当前 Composer 2.5 目录未提供独立推理强度。"
      }
    ]
  };
  const names = { codex: 'Codex', claude: 'Claude', cursor: 'Cursor' };
  const effortNames = { low: '低', medium: '中', high: '高', xhigh: '超高', max: '最高', ultra: 'Ultra' };
  const checkedAt = '2026-10-07';
  const legacyModelIds = { codex: { 'codex-code': 'gpt-6.1-sol', 'codex-general': 'gpt-6.1-sol' }, claude: { 'claude-sonnet': 'claude-sonnet-5-5', 'claude-opus': 'claude-opus-5-5', 'claude-haiku': 'claude-haiku-4-5-20251001' }, cursor: { 'cursor-auto': 'auto', 'cursor-composer': 'composer-2.5', 'cursor-sonnet': 'cursor-grok-4.7', 'cursor-codex': 'cursor-grok-4.7' } };
  function executorFromModel(model, fallback = 'codex') {
    return Object.keys(names).find(id => String(model || '').startsWith(names[id])) || (catalog[fallback] ? fallback : 'codex');
  }
  function modelFor(target) {
    return catalog[target.executor]?.find(model => model.id === target.modelId);
  }
  function normalize(target, fallback = 'codex') {
    const legacyHigh = String(target.model || '').includes('高推理');
    target.executor = catalog[target.executor] ? target.executor : executorFromModel(target.model, fallback);
    const models = catalog[target.executor];
    const modelId = legacyModelIds[target.executor]?.[target.modelId] || target.modelId;
    const model = models.find(item => item.id === modelId) || models[0];
    target.modelId = model.id;
    target.model = names[target.executor] + ' · ' + model.name;
    if (!Object.hasOwn(target, 'reasoningEffort')) target.reasoningEffort = legacyHigh ? 'high' : null;
    if (!model.efforts.includes(target.reasoningEffort)) target.reasoningEffort = null;
    global.ExecutionPermissions?.normalize(target);
    return target;
  }
  function change(target, field, value) {
    normalize(target);
    const previous = target.reasoningEffort;
    if (field === 'executor' && catalog[value]) {
      target.executor = value;
      target.modelId = catalog[value][0].id;
      target.reasoningEffort = null;
    } else if (field === 'model') target.modelId = value;
    else if (field === 'effort') target.reasoningEffort = value || null;
    normalize(target);
    return { resetEffort: previous !== null && target.reasoningEffort === null };
  }
  function snapshot(target) {
    normalize(target);
    return { executor: target.executor, modelId: target.modelId, model: target.model, reasoningEffort: target.reasoningEffort, selectionSource: 'demo', ...(modelFor(target).variantIds ? { modelVariantId: modelFor(target).variantIds[target.reasoningEffort] || null } : {}), ...(global.ExecutionPermissions ? { permissionSnapshot: global.ExecutionPermissions.snapshot(target) } : {}) };
  }
  function effortLabel(value) {
    return value === undefined ? '未记录' : value === null ? '执行器默认' : (effortNames[value] || value);
  }
  global.ModelSelection = Object.freeze({ catalog, checkedAt, names, effortNames, executorFromModel, modelFor, normalize, change, snapshot, effortLabel });
})(typeof window !== 'undefined' ? window : globalThis);
