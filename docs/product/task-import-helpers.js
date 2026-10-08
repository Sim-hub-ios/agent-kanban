/* Local prototype helpers. CSV/TSV is parsed; Excel and Issue sources are labelled demonstrations. */
(function (global) {
  'use strict';

  function clean(value) {
    return value == null ? '' : String(value).trim();
  }

  function titleKey(value) {
    return clean(value).normalize('NFKC').replace(/\s+/g, ' ').toLocaleLowerCase();
  }

  function detectDelimiter(text) {
    let quoted = false;
    let commas = 0;
    let tabs = 0;
    for (let i = 0; i < text.length; i += 1) {
      const character = text[i];
      if (character === '"') {
        if (quoted && text[i + 1] === '"') i += 1;
        else quoted = !quoted;
      } else if (!quoted) {
        if (character === ',') commas += 1;
        if (character === '\t') tabs += 1;
        if ((character === '\n' || character === '\r') && (commas || tabs)) break;
      }
    }
    return tabs > commas ? '\t' : ',';
  }

  function parseCSV(input) {
    const text = String(input == null ? '' : input).replace(/^\uFEFF/, '');
    const delimiter = detectDelimiter(text);
    const records = [];
    const recordLines = [];
    const errors = [];
    let record = [];
    let field = '';
    let quoted = false;
    let afterQuote = false;
    let line = 1;
    let recordLine = 1;

    function error(message) {
      errors.push({ row: line, column: record.length + 1, message: message });
    }
    function finishField() {
      record.push(field);
      field = '';
      afterQuote = false;
    }
    function finishRecord() {
      finishField();
      if (record.some(function (cell) { return clean(cell) !== ''; })) {
        records.push(record);
        recordLines.push(recordLine);
      }
      record = [];
    }

    for (let i = 0; i < text.length; i += 1) {
      const character = text[i];
      if (quoted) {
        if (character === '"') {
          if (text[i + 1] === '"') {
            field += '"';
            i += 1;
          } else {
            quoted = false;
            afterQuote = true;
          }
        } else if (character === '\r' || character === '\n') {
          field += '\n';
          if (character === '\r' && text[i + 1] === '\n') i += 1;
          line += 1;
        } else {
          field += character;
        }
      } else if (character === delimiter) {
        finishField();
      } else if (character === '\r' || character === '\n') {
        finishRecord();
        if (character === '\r' && text[i + 1] === '\n') i += 1;
        line += 1;
        recordLine = line;
      } else if (afterQuote) {
        if (character !== ' ' && character !== '\t') {
          error('闭合引号后只能出现分隔符或换行。');
          field += character;
          afterQuote = false;
        }
      } else if (character === '"') {
        if (field === '') quoted = true;
        else {
          error('未加引号的字段中出现了引号。');
          field += character;
        }
      } else {
        field += character;
      }
    }
    if (quoted) error('字段的引号尚未闭合。');
    if (field !== '' || record.length || afterQuote) finishRecord();

    const headers = records.length ? records.shift().map(clean) : [];
    recordLines.shift();
    records.forEach(function (row, index) {
      if (row.length !== headers.length) {
        errors.push({ row: recordLines[index], column: 0, message: '此行有 ' + row.length + ' 列，表头有 ' + headers.length + ' 列。' });
      }
    });
    if (!headers.length) errors.push({ row: 1, column: 0, message: '文件中没有可导入的表头。' });
    return { headers: headers, rows: records, errors: errors, delimiter: delimiter };
  }

  const aliases = {
    title: ['title', 'summary', '标题', '任务', '任务名称', '任务标题', '摘要'],
    description: ['description', 'body', '描述', '任务描述', '详情', '内容', '说明'],
    type: ['type', '类型', '任务类型'],
    priority: ['priority', '优先级'],
    sourceKey: ['sourcekey', 'source_key', '来源标识', '来源链接', 'issue链接', 'issue url']
  };

  function columnIndex(headers, mapping, field) {
    if (Object.prototype.hasOwnProperty.call(mapping, field)) {
      const requested = mapping[field];
      if (typeof requested === 'number') return Number.isInteger(requested) && requested >= 0 && requested < headers.length ? requested : -1;
      if (requested == null || requested === '') return -1;
      if (/^\d+$/.test(clean(requested))) {
        const index = Number(clean(requested));
        return Number.isSafeInteger(index) && index < headers.length ? index : -1;
      }
      return headers.findIndex(function (header) { return clean(header) === clean(requested); });
    }
    const index = headers.findIndex(function (header) { return aliases[field].includes(titleKey(header)); });
    return field === 'title' && index < 0 && headers.length ? 0 : index;
  }

  function taskType(value) {
    const key = titleKey(value);
    if (['bug', 'bugfix', 'fix', '缺陷', '错误', '修复', '修复bug', '修复 bug', '问题修复'].includes(key)) return 'bug';
    if (['refactor', '重构', '优化', '技术债', '代码整理'].includes(key)) return 'refactor';
    return 'feature';
  }

  function taskPriority(value) {
    const key = titleKey(value);
    if (['urgent', 'critical', '紧急', '最高', 'p0'].includes(key)) return 'urgent';
    if (['high', '高', '高优先级', 'p1'].includes(key)) return 'high';
    return 'normal';
  }

  function mapRows(headers, rows, mapping) {
    const selected = mapping || {};
    const indices = {};
    Object.keys(aliases).forEach(function (field) { indices[field] = columnIndex(headers, selected, field); });
    return rows.map(function (row, index) {
      function cell(field) { return indices[field] < 0 ? '' : clean(row[indices[field]]); }
      const title = cell('title');
      return {
        title: title,
        description: cell('description'),
        type: taskType(cell('type')),
        priority: taskPriority(cell('priority')),
        sourceKey: cell('sourceKey'),
        sourceRow: index + 2,
        error: indices.title < 0 ? '请选择标题列。' : title ? '' : '标题不能为空。'
      };
    });
  }

  function demoExcel(fileName) {
    const headers = ['标题', '描述', '类型', '优先级'];
    const rows = [
      ['修复登录页面粘贴异常', '支持从剪贴板粘贴账号，并保留输入焦点。', 'bug', 'high'],
      ['增加项目导入入口', '从本机 Git 项目创建独立看板与项目会话。', 'feature', 'normal'],
      ['重构任务状态处理', '统一阶段切换与运行状态的更新逻辑。', 'refactor', 'normal'],
      ['', '这一行用于演示缺失标题的校验，需要补充后才能导入。', 'feature', 'normal']
    ];
    const source = { kind: 'excel', fileName: clean(fileName), parsed: false, demo: true };
    return {
      demo: true,
      headers: headers,
      rows: rows,
      candidates: mapRows(headers, rows, {}),
      errors: [],
      source: source,
      provenance: source,
      notice: 'Excel 演示：以下是预设候选任务，尚未读取文件内容。真实 XLSX 解析由内置导入 Skill 实现。'
    };
  }

  function issueLocation(input) {
    const rawUrl = clean(input);
    let url;
    try { url = new URL(rawUrl); }
    catch (error) { return { error: '请输入有效的 GitHub 或 GitLab 项目 / Issue 链接。' }; }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return { error: '只支持不含账号密码的 HTTP(S) 项目 / Issue 链接。' };
    const hostname = url.hostname.toLowerCase().replace(/^www\./, '');
    let segments;
    try { segments = url.pathname.split('/').filter(Boolean).map(decodeURIComponent); }
    catch (error) { return { error: '链接路径编码无效。' }; }
    if (segments.some(function (part) { return part === '.' || part === '..' || /[\/\\]/.test(part); })) return { error: '项目 / Issue 路径无效。' };

    let provider;
    let repository;
    let issueNumber = '';
    if (hostname === 'github.com') {
      provider = 'github';
      if (segments.length < 2 || segments.length > 4 || (segments.length > 2 && segments[2] !== 'issues')) return { error: '支持 GitHub 仓库、Issues 列表或单个 Issue 链接。' };
      repository = segments.slice(0, 2).join('/').replace(/\.git$/, '');
      issueNumber = segments[3] || '';
    } else {
      const marker = segments.indexOf('-');
      const issueMarker = marker >= 2 && segments[marker + 1] === 'issues' ? marker : segments.indexOf('issues');
      if (hostname !== 'gitlab.com' && !(marker >= 2 && segments[marker + 1] === 'issues')) return { error: '支持 github.com、gitlab.com，及使用 /-/issues 路径的 GitLab 链接。' };
      provider = 'gitlab';
      if (issueMarker >= 0) {
        const suffix = segments.slice(issueMarker + (marker === issueMarker ? 2 : 1));
        if (issueMarker < 2 || suffix.length > 1) return { error: 'GitLab Issue 链接格式无效。' };
        repository = segments.slice(0, issueMarker).join('/').replace(/\.git$/, '');
        issueNumber = suffix[0] || '';
      } else {
        if (segments.length < 2 || marker >= 0) return { error: '请输入 GitLab 项目、Issues 列表或单个 Issue 链接。' };
        repository = segments.join('/').replace(/\.git$/, '');
      }
    }
    if (issueNumber && !/^[1-9]\d*$/.test(issueNumber)) return { error: 'Issue 编号应为正整数。' };
    const origin = url.protocol + '//' + hostname + (url.port ? ':' + url.port : '');
    const repositoryUrl = origin + '/' + repository.split('/').map(encodeURIComponent).join('/');
    return { provider: provider, rawUrl: rawUrl, repository: repository, repositoryUrl: repositoryUrl, issueNumber: issueNumber, error: '' };
  }

  function demoIssues(input) {
    const location = issueLocation(input);
    if (location.error) {
      const invalidSource = { kind: 'issues', rawUrl: clean(input), fetched: false, demo: true };
      return { headers: [], rows: [], demo: true, candidates: [], errors: [location.error], error: location.error, source: invalidSource, provenance: invalidSource };
    }
    const examples = [
      ['修复登录页面粘贴异常', '示例 Issue 描述：粘贴账号时输入框内容未更新。', 'bug', 'high'],
      ['增加项目导入入口', '示例 Issue 描述：支持从本机已有项目建立独立看板。', 'feature', 'normal'],
      ['重构任务状态处理', '示例 Issue 描述：统一任务状态与运行状态的更新逻辑。', 'refactor', 'normal']
    ];
    const candidates = (location.issueNumber ? examples.slice(0, 1) : examples).map(function (example, index) {
      const number = location.issueNumber || String(101 + index);
      const issueUrl = location.repositoryUrl + (location.provider === 'gitlab' ? '/-/issues/' : '/issues/') + number;
      const sourceKey = location.provider + ':' + new URL(location.repositoryUrl).host.toLowerCase() + '/' + location.repository.toLowerCase() + '#' + number;
      return {
        title: example[0], description: example[1], type: example[2], priority: example[3], sourceKey: sourceKey, sourceUrl: issueUrl, error: '',
        provenance: { kind: 'issue', provider: location.provider, rawUrl: location.rawUrl, issueUrl: issueUrl, issueNumber: number, sourceKey: sourceKey, fetched: false, demo: true }
      };
    });
    const headers = ['标题', '描述', '类型', '优先级', '来源标识', '来源链接'];
    const rows = candidates.map(function (candidate) { return [candidate.title, candidate.description, candidate.type, candidate.priority, candidate.sourceKey, candidate.provenance.issueUrl]; });
    const source = Object.assign({ kind: 'issues', fetched: false, demo: true }, location);
    return { headers: headers, rows: rows, demo: true, candidates: candidates, errors: [], error: '', source: source, provenance: source, notice: 'Issue 演示：以下是预设候选任务，尚未联网读取 Issue。真实读取与鉴权由内置导入 Skill 实现。' };
  }

  function dedupe(candidates, existingTasks) {
    const sourceKeys = new Set();
    const titles = new Set();
    (existingTasks || []).forEach(function (task) {
      const sourceKey = clean(task.sourceKey || (task.provenance && task.provenance.sourceKey) || (task.source && task.source.sourceKey));
      if (sourceKey) sourceKeys.add(titleKey(sourceKey));
      if (clean(task.title)) titles.add(titleKey(task.title));
    });
    return candidates.map(function (candidate) {
      const sourceKey = titleKey(candidate.sourceKey);
      const title = titleKey(candidate.title);
      // Distinct Issues may share a title; repository + Issue number is their identity.
      const stableIssueKey = /^(?:github|gitlab):[^/\s#]+\/[^/\s#]+(?:\/[^/\s#]+)+#[1-9]\d*$/.test(sourceKey);
      const bySource = sourceKey && sourceKeys.has(sourceKey);
      const byTitle = !stableIssueKey && title && titles.has(title);
      const duplicate = Boolean(bySource || byTitle);
      const reason = bySource ? '来源标识已存在。' : byTitle ? '相同标题的任务已存在。' : '';
      if (!candidate.error) {
        if (sourceKey) sourceKeys.add(sourceKey);
        if (title) titles.add(title);
      }
      return Object.assign({}, candidate, { duplicate: duplicate, duplicateReason: reason, reason: reason });
    });
  }

  global.TaskImportHelpers = Object.freeze({ parseCSV: parseCSV, mapRows: mapRows, demoExcel: demoExcel, demoIssues: demoIssues, dedupe: dedupe });
})(typeof window !== 'undefined' ? window : globalThis);
