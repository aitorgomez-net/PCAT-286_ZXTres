"""Generate opcode-local executor strobes without weakening REP permission.

Only a positive conjunction is changed, including a guarded OR branch. Its
expanded logical guard must be false for both timed REP branch words with
every state/context atom arbitrary. All state-only
qualifiers, subservice enables and REP strobes retain the original permission.
"""
import re
import hashlib


REP_ZERO_ATOMS = ('immediate_operation', 'register_decode', 'unary_direct')
# Actual procedural table fragments; formally proved with their original
# SystemVerilog before qualification. Changes require a new audited contract.
REP_DECODER_SHA256 = '16b7a8c0052cb112479673a13ef21a16a5294da34eb2a6689cbaaea2a06a244d'


def rep_decoder_fragments(source):
    immediate = source[source.index('    always_comb begin\n        immediate_operation'):
                       source.index('    // ModR/M and all displacement bytes')]
    registers = source[source.index('    always_comb begin\n        register_decode'):
                       source.index('    assign register_a_index')]
    assert hashlib.sha256((immediate + registers).encode()).hexdigest() == REP_DECODER_SHA256
    return immediate + registers


def split_top(text, operator):
    parts = []
    level = 0
    start = 0
    i = 0
    while i < len(text):
        if text[i] in '([':
            level += 1
        elif text[i] in ')]':
            level -= 1
        elif level == 0 and text.startswith(operator, i):
            parts.append(text[start:i].strip())
            i += len(operator)
            start = i
            continue
        i += 1
    parts.append(text[start:].strip())
    return parts


def unwrap(text):
    text = text.strip()
    while text.startswith('(') and text.endswith(')'):
        level = 0
        for i, char in enumerate(text):
            if char == '(':
                level += 1
            elif char == ')':
                level -= 1
            if level == 0:
                break
        if i != len(text) - 1:
            break
        text = text[1:-1].strip()
    return text


def opcode_expression(text, aliases, constants, seen=()):
    text = unwrap(text)
    if '?' in text:
        return None
    for token, kind in [('||', 'or'), ('&&', 'and')]:
        parts = split_top(text, token)
        if len(parts) > 1:
            children = [opcode_expression(p, aliases, constants, seen) for p in parts]
            return (kind, children) if all(c is not None for c in children) else None
    if text.startswith('!'):
        child = opcode_expression(text[1:], aliases, constants, seen)
        return ('not', child) if child is not None else None
    match = re.fullmatch(r'operation\s*(==|!=|<=|>=|<|>)\s*spk286_microcode_pkg::(MC_\w+)', text)
    if match and match[2] in constants:
        return ('compare', match[1], constants[match[2]])
    if text in aliases and text not in seen:
        return opcode_expression(aliases[text], aliases, constants, (*seen, text))
    return None


def evaluate(tree, operation):
    if tree[0] == 'compare':
        return {'==': operation == tree[2], '!=': operation != tree[2],
                '<=': operation <= tree[2], '>=': operation >= tree[2],
                '<': operation < tree[2], '>': operation > tree[2]}[tree[1]]
    if tree[0] == 'not':
        return not evaluate(tree[1], operation)
    values = [evaluate(child, operation) for child in tree[1]]
    return all(values) if tree[0] == 'and' else any(values)


def boolean_expression(text, aliases, constants, seen=()):
    """Preserve logical operators; abstract other context atoms independently.

    This deliberately overapproximates context correlations. An unresolved
    arithmetic/comparison/alias atom may be either Boolean value. Ternaries
    are never rewritten. Opcode comparisons retain their exact eight-bit value.
    """
    text = unwrap(text)
    for token, kind in [('||', 'or'), ('&&', 'and')]:
        parts = split_top(text, token)
        if len(parts) > 1:
            return (kind, [boolean_expression(p, aliases, constants, seen) for p in parts])
    if text.startswith('!'):
        return ('not', boolean_expression(text[1:], aliases, constants, seen))
    if text in ('allowed', 'implementation_allowed'):
        return ('permission', text)
    if text in REP_ZERO_ATOMS:
        return ('rep_zero', text)
    match = re.fullmatch(r'operation\s*(==|!=|<=|>=|<|>)\s*spk286_microcode_pkg::(MC_\w+)', text)
    if match and match[2] in constants:
        return ('compare', match[1], constants[match[2]])
    if text in aliases and text not in seen and '?' not in aliases[text]:
        return boolean_expression(aliases[text], aliases, constants, (*seen, text))
    if text in ("1'b0", "1'd0", '0'):
        return ('constant', False)
    if text in ("1'b1", "1'd1", '1'):
        return ('constant', True)
    return ('context', text)


def possibilities(tree, operation):
    kind = tree[0]
    if kind in ('permission', 'context'):
        return True, True
    if kind == 'rep_zero':
        return (False, True) if operation in (121, 128) else (True, True)
    if kind in ('compare', 'constant'):
        value = evaluate(tree, operation) if kind == 'compare' else tree[1]
        return value, not value
    if kind == 'not':
        yes, no = possibilities(tree[1], operation)
        return no, yes
    values = [possibilities(child, operation) for child in tree[1]]
    if kind == 'and':
        return all(yes for yes, _ in values), any(no for _, no in values)
    return any(yes for yes, _ in values), all(no for _, no in values)


def repeat_excluded_permission_guard(expression, aliases, constants, repeat_words):
    """Find the positive conjunction containing the one permission token.

    Other OR branches may remain true during REP (for example an already
    active descriptor service). The branch containing ``allowed`` alone must
    be false for every arbitrary context atom under both REP words. Never
    cross a negation or ternary, and never infer lifecycle correlations.
    """
    expression = unwrap(expression)
    if '?' in expression or expression.startswith('!'):
        return None
    alternatives = split_top(expression, '||')
    if len(alternatives) > 1:
        for branch in alternatives:
            guard = repeat_excluded_permission_guard(branch, aliases, constants, repeat_words)
            if guard is not None:
                return guard
        return None
    terms = split_top(expression, '&&')
    if len(terms) > 1:
        if any(unwrap(term) == 'allowed' for term in terms):
            tree = boolean_expression(expression, aliases, constants)
            if not any(possibilities(tree, word)[0] for word in repeat_words):
                return expression
        for term in terms:
            guard = repeat_excluded_permission_guard(term, aliases, constants, repeat_words)
            if guard is not None:
                return guard
    return None


def generate(source, package):
    constants = {name: int(value) for name, value in re.findall(
        r'localparam\s+logic\s+\[MC_WORD_WIDTH-1:0\]\s+(MC_\w+)\s*=\s*8\'d(\d+);', package)}
    repeat_words = [constants[name] for name in ('MC_BRANCH_REPEAT_EMPTY', 'MC_BRANCH_REPEAT_CONTINUE')]
    assert repeat_words == [121, 128]
    rep_decoder_fragments(source)
    pattern = re.compile(r'^    assign (\w+)\s*=\s*(.*?);', re.M | re.S)
    assignments = list(pattern.finditer(source))
    aliases = {m[1]: m[2] for m in assignments}
    pure_aliases = {name: expression for name, expression in aliases.items()
                    if opcode_expression(expression, aliases, constants) is not None}
    changes = []

    def rewrite(match):
        expression = match[2]
        if len(re.findall(r'\ballowed\b', expression)) != 1 or '?' in expression:
            return match[0]
        guard = repeat_excluded_permission_guard(expression, aliases, constants, repeat_words)
        if guard is None:
            return match[0]
        replacement = re.sub(r'\ballowed\b', 'implementation_allowed', match[0])
        # Expand aliases from the original source for both sides. Their
        # replacements are independently proved equal, so this simultaneous
        # cutpoint contract retains every arbitrary state/context predicate.
        changes.append({'signal': match[1], 'guard': guard,
                        'original_statement': match[0],
                        'replacement_statement': replacement,
                        'original_model': boolean_expression(expression, aliases, constants),
                        'replacement_model': boolean_expression(re.sub(r'\ballowed\b', 'implementation_allowed', expression), aliases, constants)})
        return changes[-1]['replacement_statement']

    result = pattern.sub(rewrite, source)
    assert len(changes) >= 50, 'Unexpectedly few opcode-local strobes'
    assert not any(c['signal'] in ('string_empty', 'string_continue', 'allowed') for c in changes)
    assert result.count('module spk286_micro_executor #(') == 1
    result = result.replace('module spk286_micro_executor #(', 'module spk286_profiled_micro_executor #(', 1)
    assert result.count('    input  logic operation_valid,') == 1
    result = result.replace('    input  logic operation_valid,',
                            '    input  logic operation_valid,\n    input  logic implementation_operation_valid,', 1)
    allowed = next(m[0] for m in assignments if m[1] == 'allowed')
    local_allowed = allowed.replace('assign allowed', 'assign implementation_allowed').replace(
        'operation_valid', 'implementation_operation_valid')
    assert result.count(allowed) == 1
    result = result.replace(allowed, allowed + '\n    logic implementation_allowed;\n' + local_allowed, 1)
    return result, {'repeat_words': repeat_words, 'constants': constants,
                    'pure_aliases': pure_aliases, 'changes': changes,
                    'procedural_rep_zero': {'atoms': REP_ZERO_ATOMS, 'table_sha256': REP_DECODER_SHA256}}
