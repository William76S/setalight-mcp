#!/usr/bin/env python3
"""Local macOS set.a.light MCP server. Python 3.10+, standard library only."""
from __future__ import annotations

import argparse
import base64
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys
import tempfile
import threading
import time
import re
import copy

VERSION = "0.4.0"
ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "SetALight MCP.app" / "Contents" / "MacOS" / "setalight-input"
PROTOCOLS = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")
MAX_LINE = 1_048_576
MAX_HELPER_INPUT = 65_536
INSTRUCTIONS = """Control only the running macOS set.a.light 3D v2.5 app. First call status.
Prefer inspect_ui, select_object and set_parameters over individual mouse/keyboard calls.
Submit all desired fields together to set_parameters; it batches stable fields and reads back
the result. discover_parameters scans the selected object's inspector. Parameter names and
choice values come from the visible English UI, not an internal scene API. Never invent a
control or assume a sent input succeeded. Unsupported or ambiguous controls return errors.
Raw input requires the observation returned by screenshot/inspect_ui (or the last observation
in this session). Re-observe after any layout change or partial failure. Cancellation stops
remaining input but does not undo changes. Avoid concurrent human input. Accessibility and
Screen Recording permissions are separate; request_access requires explicit user approval.
The server never parses or rewrites .set files and does not make network connections."""


def schema(properties=None, required=()):
    return {"type": "object", "properties": properties or {}, "required": list(required), "additionalProperties": False}


def tool(name, description, properties=None, required=(), read_only=False, idempotent=False):
    return {"name": name, "description": description, "inputSchema": schema(properties, required),
            "annotations": {"readOnlyHint": read_only, "destructiveHint": not read_only,
                            "idempotentHint": idempotent, "openWorldHint": False}}


NUMBER = {"type": "number"}
POINT = {"x": NUMBER, "y": NUMBER}
DURATION = {"type": "number", "minimum": 20, "maximum": 1000}
BATCH_NAMES = ("focus", "click", "click_hid", "scroll_hid", "drag_hid", "keypress", "type_text")
GEOMETRY = schema({k: NUMBER for k in ("X", "Y", "Width", "Height")}, ("X", "Y", "Width", "Height"))
OBSERVATION = schema({"pid": {"type": "integer", "minimum": 1}, "windowId": {"type": "integer", "minimum": 1}, "bounds": GEOMETRY, "capturedAtMs": NUMBER}, ("pid", "windowId", "bounds", "capturedAtMs"))
TOOLS = [
    tool("status", "Read running state, permissions, visible window bounds and displays. Works when set.a.light is closed. No permission dialogs or focus changes.", read_only=True, idempotent=True),
    tool("screenshot", "Capture only one visible set.a.light window as an inline PNG. Defaults to the largest window; use windowId from status for a dialog. Requires existing Screen Recording permission; never requests access. Returns exact image-to-screen coordinate mapping. Does not focus the app.",
         {"windowId": {"type": "integer", "minimum": 1, "maximum": 4294967295}, "maxWidth": {"type": "integer", "minimum": 640, "maximum": 2560}}, read_only=True, idempotent=True),
    tool("request_access", "Ask macOS for the named permission ONLY after explicit user approval for SetALight MCP at action time. Accessibility enables input; screen_recording enables window screenshots. confirmed must be true. This requests, never grants, access.",
         {"confirmed": {"type": "boolean", "enum": [True]}, "permission": {"type": "string", "enum": ["accessibility", "screen_recording"]}}, ("confirmed",)),
    tool("focus", "Activate only the already-running set.a.light app. Never launches it.", idempotent=True),
    tool("fit_window", "Fit set.a.light's main window to the primary screen through Accessibility. Does not change display settings.", idempotent=True),
    tool("click", "Verified Unity input: focus set.a.light, validate global screen point and Accessibility hit owner, then left click via HID. Inspect a current screenshot first. Returns an error on rejected or interrupted input.", {**POINT, "durationMs": DURATION}, ("x", "y")),
    tool("click_hid", "Compatibility alias for click; same validated HID left click. Coordinates are global screen points, not image pixels.", {**POINT, "durationMs": DURATION}, ("x", "y")),
    tool("scroll_hid", "Scroll at the observed global screen point via HID. Nonzero integer deltaY in pixels: positive up, negative down, magnitude <=2000. Validates Accessibility hit owner.", {**POINT, "deltaY": {"type": "integer", "minimum": -2000, "maximum": 2000}}, ("x", "y", "deltaY")),
    tool("drag_hid", "Smooth validated HID drag within set.a.light. Rechecks foreground/path hit ownership and releases the button on interruption. Re-observe before any retry.", {"fromX": NUMBER, "fromY": NUMBER, "toX": NUMBER, "toY": NUMBER, "durationMs": {"type": "number", "minimum": 200, "maximum": 2000}}, ("fromX", "fromY", "toX", "toY")),
    tool("keypress", "Send an allowed key/chord only while set.a.light is frontmost. Examples cmd+a, return, escape, shift+tab. Global app/workspace switch shortcuts are blocked. This may change or save the project.", {"key": {"type": "string", "minLength": 1, "maxLength": 80}}, ("key",)),
    tool("type_text", "Type Unicode into the already-focused set.a.light field without using the clipboard. At most 4096 UTF-16 units. Does not clear existing contents or press Enter.", {"text": {"type": "string", "maxLength": 4096}}, ("text",)),
]
ACTION = {"oneOf": [{**item["inputSchema"], "properties": {"command": {"type": "string", "const": item["name"]}, **item["inputSchema"]["properties"]}, "required": ["command", *item["inputSchema"]["required"]]} for item in TOOLS if item["name"] in BATCH_NAMES]}
TOOLS.append(tool("batch", "Run 1..20 known input steps serially. No permission requests, screenshots, or nested batches. Stops on error, rejected input, or foreground change, reporting completed steps and failedIndex. Not atomic: a failed action may be partly applied.", {"actions": {"type": "array", "items": ACTION, "minItems": 1, "maxItems": 20}}, ("actions",)))
BY_NAME = {item["name"]: item for item in TOOLS}
for item in TOOLS:
    if item['name'] in (*BATCH_NAMES[1:], 'batch'):
        item['inputSchema']['properties']['observation'] = OBSERVATION
BY_NAME['keypress']['inputSchema']['properties']['transport'] = {'type': 'string', 'enum': ['pid', 'hid']}
for name in ('click','click_hid'):
    BY_NAME[name]['inputSchema']['properties']['clickCount'] = {'type':'integer','minimum':1,'maximum':2}
# Rebuild the nested schemas after adding keyboard transport; observation is batch-wide.
ACTION['oneOf'] = [{**item['inputSchema'], 'properties': {'command': {'type':'string','const':item['name']}, **{k:v for k,v in item['inputSchema']['properties'].items() if k != 'observation'}}, 'required':['command',*item['inputSchema']['required']]} for item in TOOLS if item['name'] in BATCH_NAMES]

VALUE = {'anyOf': [{'type':'number'}, {'type':'boolean'}, {'type':'string','minLength':1,'maxLength':200}]}
VALUES = {'type':'object','minProperties':1,'maxProperties':32,'additionalProperties':VALUE}
TARGET = {'type':'string','minLength':1,'maxLength':200}
TOOLS.extend([
    tool('inspect_ui', 'Read the current window with local OCR. Returns visible parameter IDs, values, control types, object rows and an observation. English UI required. No input; optional inline image.', {'includeImage':{'type':'boolean'}}, read_only=True, idempotent=True),
    tool('discover_parameters', 'Scan the selected object inspector (at most 12 scrolls), returning every recognized parameter and its current value. Scrolls the panel; does not change scene values. Hidden/collapsed controls are not invented.', {'scan':{'type':'boolean'}}, idempotent=True),
    tool('select_object', 'Select an exact object name from the observed SETLIST. Searches by scrolling; duplicate matches require occurrence (1-based). Verifies selection through the inspector.', {'name':TARGET,'occurrence':{'type':'integer','minimum':1,'maximum':100}}, ('name',), idempotent=True),
    tool('set_parameters', 'Set multiple parameters on the current object or target object. Use IDs from inspect_ui/discover_parameters. Numeric fields are batched, choices and toggles observed individually. Preflights types; verifies every requested value by OCR. No automatic retry or rollback after partial failure.', {'values':VALUES,'target':TARGET,'expected':{'type':'object','additionalProperties':VALUE,'maxProperties':32}}, ('values',)),
    tool('list_options', 'Open one observed choice control, read visible choices, then close it. Does not select a value.', {'parameter':TARGET}, ('parameter',)),
    tool('choose_option', 'Set one choice by its exact displayed text, then read back the control. Returns an error if the value cannot be verified.', {'parameter':TARGET,'value':TARGET}, ('parameter','value')),
    tool('click_control', 'Click exact visible text in an optional region. Requires an observation. Useful for sections, tabs and other controls that have no parameter setter; returns a fresh inspection, not a claim that a scene value changed.', {'text':TARGET,'region':{'type':'string','enum':['window','inspector','setlist','toolbar','library']},'observation':OBSERVATION}, ('text','observation')),
    tool('menu_command', 'Open File, Edit or Settings and click one exact visible menu item. Returns a new inspection. For submenu items, call click_control on the returned observation. Does not claim a setting changed.', {'menu':{'type':'string','enum':['File','Edit','Settings']},'item':TARGET}, ('menu','item')),
    tool('save_project', 'Save through the native Save As dialog to an absolute .set path. Parent directory must exist. Refuses existing files unless overwrite=true. Verifies a nonempty file and the displayed project title.', {'path':{'type':'string','minLength':1,'maxLength':4096},'overwrite':{'type':'boolean'}}, ('path',)),
    tool('render', 'Create a snapshot of the active scene and render it through the VIEW workspace. output_directory must be the project image folder (same basename as the displayed project). Waits for a new stable JPEG, then reports its path. Timeout does not mean completion.', {'output_directory':{'type':'string','minLength':1,'maxLength':4096},'wait_seconds':{'type':'integer','minimum':5,'maximum':90}}, ('output_directory',)),
    tool('scene_command', 'Issue a named app shortcut after clearing text-field focus. Verifies snapshots and light toggles; other shortcuts return changed readable parameters and inspection. Does not silently repeat commands.', {'action':{'type':'string','enum':['undo','redo','snapshot','aim_at_model','toggle_solo','toggle_light','toggle_tripod','focus_selection','swap_views','toggle_library','toggle_inspector','mirror_selected','open_pose_control']}}, ('action',)),
    tool('configure_scene', 'Configure up to eight named objects in one call. Each object accepts target, values and optional expected. Stops on first failure and reports completed objects. Maximum 48 parameters and 120 seconds total; partial changes are never rolled back automatically.', {'objects':{'type':'array','minItems':1,'maxItems':8,'items':schema({'target':TARGET,'values':VALUES,'expected':{'type':'object','additionalProperties':VALUE}},('target','values'))}}, ('objects',)),
])
BY_NAME = {item['name']:item for item in TOOLS}

LOCAL = threading.local()
OPERATION_LOCK = threading.Lock()
LAST_OBSERVATION = None
LAST_VIEW = None
SESSION_RESTRICTIONS = {}


class ToolFailure(Exception):
    def __init__(self, code, message, **details):
        super().__init__(message)
        self.code, self.message, self.details = code, message, details


def check_cancelled():
    event = getattr(LOCAL, 'cancel_event', None)
    if event is not None and event.is_set():
        raise ToolFailure('CANCELLED', 'Operation stopped. Already-applied changes are not rolled back.')
    if time.monotonic() > getattr(LOCAL, 'deadline', math.inf):
        raise ToolFailure('TIMEOUT', 'Operation reached its 120 second time limit. Inspect partial results before continuing.')


KEY_NAMES = set('a s d f h g z x c v b q w e r y t 1 2 3 4 6 5 equal 9 7 minus 8 0 rightbracket o u leftbracket i p return l j apostrophe k semicolon backslash comma slash n m period enter tab space backspace escape delete home end pageup pagedown left right down up'.split())
MODIFIERS = {'cmd':'cmd','command':'cmd','super':'cmd','ctrl':'ctrl','control':'ctrl','alt':'alt','option':'alt','shift':'shift'}


def validate_key(value):
    parts = value.lower().split('+')
    if parts[-1] not in KEY_NAMES or any(x not in MODIFIERS for x in parts[:-1]):
        raise RPCError(-32602, 'Unsupported key or modifier')
    modifiers = {MODIFIERS[x] for x in parts[:-1]}
    if ('cmd' in modifiers and parts[-1] in ('tab','space','h')) or ({'cmd','alt'} <= modifiers and parts[-1] == 'escape') or ('ctrl' in modifiers and parts[-1] in ('left','right','up','down')):
        raise RPCError(-32602, 'Global application/workspace shortcut is not allowed')


class RPCError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def json_loads(value):
    def reject_constant(value):
        raise ValueError("Non-finite JSON number")
    return json.loads(value, parse_constant=reject_constant)


def utf16_length(value):
    try:
        return len(value.encode("utf-16-le")) // 2
    except UnicodeEncodeError as exc:
        raise RPCError(-32602, "Text contains an unpaired Unicode surrogate") from exc


def validate_schema(value, spec, path='arguments'):
    if 'oneOf' in spec or 'anyOf' in spec:
        alternatives = spec.get('oneOf', spec.get('anyOf'))
        for candidate in alternatives:
            try:
                validate_schema(value, candidate, path)
                return
            except RPCError:
                pass
        raise RPCError(-32602, f'Invalid value: {path}')
    kind = spec.get('type')
    if kind in ('number', 'integer'):
        valid = type(value) in (int, float) and (kind != 'integer' or type(value) is int)
        try:
            valid = valid and math.isfinite(value)
        except OverflowError:
            valid = False
        if not valid or value < spec.get('minimum', -math.inf) or value > spec.get('maximum', math.inf):
            raise RPCError(-32602, f'Invalid finite {kind}: {path}')
    elif kind == 'string':
        if not isinstance(value, str) or not spec.get('minLength', 0) <= len(value) <= spec.get('maxLength', MAX_LINE):
            raise RPCError(-32602, f'Invalid string: {path}')
        utf16_length(value)
    elif kind == 'boolean':
        if type(value) is not bool:
            raise RPCError(-32602, f'Invalid boolean: {path}')
    elif kind == 'array':
        if not isinstance(value, list) or not spec.get('minItems', 0) <= len(value) <= spec.get('maxItems', 10000):
            raise RPCError(-32602, f'Invalid array: {path}')
        for index, item in enumerate(value):
            validate_schema(item, spec.get('items', {}), f'{path}[{index}]')
    elif kind == 'object':
        if not isinstance(value, dict) or not spec.get('minProperties', 0) <= len(value) <= spec.get('maxProperties', 1000):
            raise RPCError(-32602, f'Invalid object: {path}')
        properties = spec.get('properties', {})
        if set(spec.get('required', ())) - set(value):
            raise RPCError(-32602, f'Missing arguments: {path}')
        for key, item in value.items():
            if key in properties:
                validate_schema(item, properties[key], f'{path}.{key}')
            elif spec.get('additionalProperties', True) is False:
                raise RPCError(-32602, f'Unknown argument: {path}.{key}')
            elif isinstance(spec.get('additionalProperties'), dict):
                validate_schema(item, spec['additionalProperties'], f'{path}.{key}')
    if 'enum' in spec and value not in spec['enum']:
        raise RPCError(-32602, f'Invalid choice: {path}')
    if 'const' in spec and value != spec['const']:
        raise RPCError(-32602, f'Invalid constant: {path}')


def validate_action(name, args):
    if not isinstance(name, str) or name not in BY_NAME:
        raise RPCError(-32602, 'Unknown tool')
    validate_schema(args, BY_NAME[name]['inputSchema'])
    if name == 'request_access' and args['confirmed'] is not True:
        raise RPCError(-32602, 'Explicit user confirmation is required')
    if name == 'scroll_hid' and args['deltaY'] == 0:
        raise RPCError(-32602, 'deltaY must not be zero')
    if name == 'type_text' and utf16_length(args['text']) > 4096:
        raise RPCError(-32602, 'Text exceeds 4096 UTF-16 units')
    if name == 'keypress':
        validate_key(args['key'])
    if name == 'configure_scene' and sum(len(o['values']) for o in args['objects']) > 48:
        raise RPCError(-32602, 'configure_scene accepts at most 48 parameters')
    if name in ('set_parameters','configure_scene'):
        objects = args['objects'] if name == 'configure_scene' else [args]
        for obj in objects:
            for field in ('values','expected'):
                keys=list(obj.get(field,{}))
                normalized=[normalize(k) for k in keys]
                if any(not k for k in normalized) or len(set(normalized)) != len(keys):
                    raise RPCError(-32602,'Parameter names must be nonempty and unique after normalization')
    if name == 'batch':
        for action in args['actions']:
            if not isinstance(action, dict) or action.get('command') not in BATCH_NAMES:
                raise RPCError(-32602, 'Invalid batch action')
            validate_action(action['command'], {k:v for k,v in action.items() if k != 'command'})
        if sum(utf16_length(a.get('text', '')) for a in args['actions']) > 4096:
            raise RPCError(-32602, 'Combined text exceeds 4096 UTF-16 units')


@contextmanager
def helper_lock():
    """Serialize helper calls across MCP clients and the CLI; never queue stale input."""
    import fcntl
    path = Path(tempfile.gettempdir()) / f"setalight-mcp-{os.getuid()}.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
            raise OSError("Unsafe lock file")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield fd
    finally:
        os.close(fd)


def tool_result(data):
    content = [{"type": "text", "text": json.dumps(data, ensure_ascii=True, allow_nan=False)}]
    return {"content": content, "structuredContent": data, "isError": not data.get("ok", False)}


def native(command, **args):
    """One bounded helper process; the workflow owns the inherited cross-client lock."""
    global LAST_OBSERVATION
    check_cancelled()
    payload = json.dumps({'command': command, **args}, ensure_ascii=True, allow_nan=False)
    if len(payload.encode()) > MAX_HELPER_INPUT:
        raise RPCError(-32602, 'Helper request exceeds 64 KiB')
    fd = getattr(LOCAL, 'lock_fd', None)
    with subprocess.Popen([str(HELPER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, pass_fds=(() if fd is None else (fd,))) as proc:
        started = time.monotonic()
        first = True
        while True:
            try:
                stdout, _ = proc.communicate(payload if first else None, timeout=0.10)
                break
            except subprocess.TimeoutExpired:
                first = False
                event = getattr(LOCAL, 'cancel_event', None)
                timed_out = time.monotonic() > min(started + 120, getattr(LOCAL, 'deadline', math.inf))
                if (event is not None and event.is_set()) or timed_out:
                    proc.terminate()
                    try:
                        proc.communicate(timeout=3)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.communicate()
                    raise ToolFailure('TIMEOUT' if timed_out else 'CANCELLED',
                                      'Operation stopped. Already-applied input is not rolled back.')
        check_cancelled()
        data = json_loads(stdout)
        if not isinstance(data, dict) or type(data.get('ok')) is not bool:
            raise ValueError('Invalid helper response')
        if proc.returncode and data['ok']:
            raise ValueError('Contradictory helper exit status')
    detail = data.get('result', {})
    if not data['ok'] or any(detail.get(k) is False for k in ('clicked','scrolled','dragged','frontmostAfter')) or detail.get('interrupted'):
        message = data.get('error', detail.get('error', detail.get('reason', 'Input rejected or interrupted; re-observe before retrying.')))
        code = next((c for c in ('CANCELLED','STALE_OBSERVATION','FOCUS_LOST') if c in message), 'INPUT_FAILED')
        raise ToolFailure(code, message, partial=detail)
    if detail.get('observation'):
        LAST_OBSERVATION = detail['observation']
    return detail


def normalize(text):
    return re.sub(r'[\W_]+', '_', text.casefold()).strip('_')


def center(item):
    return {'x': item['screenX'], 'y': item['screenY']}


def numeric(text):
    match = re.fullmatch(r'\s*([+-]?(?:\d+(?:[.,]\d*)?|[.,]\d+))\s*(?:m|cm|mm|K|°|•|%|Ws|W|s)?\s*', text)
    return float(match[1].replace(',', '.')) if match else None


def in_region(item, view, region):
    r, b = item['rect'], view['bounds']
    x, y = r['x'] + r['width']/2, r['y'] + r['height']/2
    boundary = view.get('inspectorWidth', min(270, b['Width'] * .20))
    setlist = next((t for t in view['texts'] if normalize(t['text']) == 'setlist'), None)
    if region == 'window': return True
    if region == 'inspector': return r['x'] < boundary and 62 < y < b['Height'] - 28
    if region == 'toolbar': return y < 130
    if region == 'setlist': return bool(setlist and x > b['Width'] * .5 and y > setlist['rect']['y'])
    if region == 'library': return x > boundary and y > b['Height'] * .5
    return False


def parse_view(view):
    """Conservative label/value pairing: only controls actually present in the image."""
    view = copy.deepcopy(view)
    texts, bounds = view['texts'], view['bounds']
    words = ' '.join(t['text'] for t in texts)
    view['blockingDialog'] = None
    if re.search(r'only available in.*studio.?edition', words, re.I):
        view['blockingDialog'] = {'code':'EDITION_RESTRICTED', 'message':'This control requires the STUDIO edition. The application has blocked the operation.'}
    elif any(t['text'].startswith('Loading ') for t in texts):
        view['blockingDialog'] = {'code':'APP_BUSY', 'message':'The application is still loading a project.'}
    elif 'Recent Files' in words and 'New Shooting' in words:
        view['blockingDialog'] = {'code':'NO_PROJECT', 'message':'Open a project before setting scene parameters.'}
    elif any(t['text'] == 'Information' and bounds['Width']*.2 < t['rect']['x'] < bounds['Width']*.8 for t in texts) and any(normalize(t['text']) == 'ok' for t in texts):
        view['blockingDialog'] = {'code':'MODAL_DIALOG', 'message':'An application information dialog is open. Inspect and dismiss it before continuing.'}
    # The left inspector ends before the camera toolbar. It can be resized.
    sensor = next((t for t in texts if re.fullmatch(r'Full Frame|APS-C.*|Micro Four.*', t['text'], re.I) and 60 < t['rect']['y'] < 100), None)
    view['inspectorWidth'] = min(360, sensor['rect']['x'] - 40) if sensor else min(270, bounds['Width'] * .20)
    left = [t for t in texts if in_region(t, view, 'inspector')]
    controls = {}
    def add(key, kind, value, item, label=None):
        if key in controls:
            controls[key]['ambiguous'] = True
            return
        controls[key] = {'id':key, 'kind':kind, 'value':value, 'display':item['text'],
                         'label':label or key, 'point':center(item), 'confidence':item['confidence']}
        if kind == 'number' and key in ('pitch','roll','yaw'):
            controls[key]['tolerance'] = 0.05  # Unity's Euler-angle recomputation.
    for label in left:
        raw, r = label['text'].strip(), label['rect']
        if not raw.endswith(':') or r['x'] > view['inspectorWidth'] * .55:
            continue
        row = [t for t in left if t['rect']['x'] > r['x'] + r['width'] + 6 and abs(t['screenY'] - label['screenY']) < 8]
        candidates = [t for t in row if numeric(t['text']) is not None]
        if len(candidates) == 1:
            item = candidates[0]
            add(normalize(raw), 'number', numeric(item['text']), item, raw.rstrip(':'))
    # Paired temperature readouts have no colon.
    for label in left:
        if label['text'].lower().strip() in ('color temperature', 'colour temperature'):
            row = [t for t in left if t['rect']['x'] > label['rect']['x'] + label['rect']['width'] and abs(t['screenY'] - label['screenY']) < 8 and numeric(t['text']) is not None]
            if len(row) == 1:
                key = 'color_temperature' if 'color_temperature' not in controls else 'modeling_temperature'
                add(key, 'number', numeric(row[0]['text']), row[0], label['text'])
    transform = next((t for t in left if normalize(t['text']).endswith('transform')), None)
    if transform:
        power = [t for t in left if 90 < t['rect']['x'] < 185 and transform['rect']['y'] - 50 < t['rect']['y'] < transform['rect']['y'] - 8 and numeric(t['text']) is not None]
        if len(power) == 1: add('power', 'number', numeric(power[0]['text']), power[0], 'Power')
    choices = {'light shaper':'light_shaper', 'variants':'variant', 'flash head variant':'flash_head_variant',
               'lens':'lens', 'gel':'gel', 'texture':'texture', 'pose':'pose', 'expression':'expression', 'hairstyle':'hairstyle'}
    for label in left:
        clean = re.sub(r'^[^A-Za-z]*', '', label['text']).lower()
        kind = next((v for k,v in choices.items() if clean == k or clean.endswith(' '+k)), None)
        if kind is None and re.search(r'\d+\s*ws\s*\(.*\)', label['text'], re.I): kind = 'flash_head'
        if kind:
            below = [t for t in left if 16 < t['rect']['y'] - label['rect']['y'] < 40 and t['rect']['x'] < view['inspectorWidth'] * .7 and not t['text'].endswith(':')]
            if len(below) == 1: add(kind, 'choice', below[0]['text'], below[0], label['text'])
    for label in left:
        match = re.fullmatch(r'([vV✓✔•☐]?)\s*(Flash active|Continuous Light active|Prop|Full)', label['text'])
        if match:
            state = True if match[1] in ('v','V','✓','✔') else False if match[1] in ('•','☐') else (label.get('leftMarkerBrightPixels',0) > 5 if label['rect']['x'] > 30 else None)
            if state is not None: add(normalize(match[2]), 'boolean', state, label, match[2])
    for item in texts:
        r, raw = item['rect'], item['text'].strip()
        if not (view['inspectorWidth'] < r['x'] < bounds['Width'] * .60 and 62 < r['y'] < (115 if raw.startswith('ND') else 90)): continue
        key = None
        if re.fullmatch(r'Full Frame|APS-C.*|Micro Four.*', raw, re.I): key='sensor'
        elif re.fullmatch(r'\d+:\d+', raw): key='aspect_ratio'
        elif re.fullmatch(r'\d+(?:-\d+)? mm', raw): key='lens'
        elif re.fullmatch(r'(?:1/)?\d+(?:\.\d+)? s', raw): key='shutter_speed'
        elif re.fullmatch(r'f/\d+(?:\.\d+)?', raw): key='aperture'
        elif re.fullmatch(r'ISO\s*\d+', raw): key='iso'
        elif re.fullmatch(r'\d+K', raw): key='white_balance'
        elif re.fullmatch(r'ND\s*\d+', raw): key='nd_filter'
        if key:
            add(key, 'choice', raw, item, key.replace('_',' ').title())
            # Toolbar text is also used as a wheel-edit readout. Open the
            # chooser with its adjacent arrow, rather than the numeric text.
            controls[key]['valuePoint'] = center(item)
            controls[key]['point'] = {'x':bounds['X']+r['x']-14, 'y':item['screenY']}
    for slider in view.get('sliders', []):
        for toggle in slider.get('toggles', []):
            controls[toggle['id']] = {**toggle,'kind':'boolean','display':str(toggle['value']),'label':toggle['id'],'confidence':1}
        if slider['id'] in controls:
            controls[slider['id']]['kind'] = 'slider'
            controls[slider['id']]['slider'] = slider
    # A readout without a detected track must not be treated as a text field.
    for key in ('power','color_temperature','modeling_temperature'):
        if key in controls and controls[key]['kind'] == 'number':
            controls[key]['kind'] = 'unresolved_slider'
    view['parameters'] = list(controls.values())
    titles = [t for t in left if 62 < t['rect']['y'] < 92]
    view['selectedObject'] = titles[0]['text'] if len(titles) == 1 else None
    for control in view['parameters']:
        restriction=SESSION_RESTRICTIONS.get((view['observation']['pid'],view['selectedObject'],control['id']))
        if restriction:
            control['available']=False
            control['restriction']=restriction
    all_row=next((t for t in texts if t['text']=='All' and in_region(t,view,'setlist')),None)
    view['objects'] = [{'name':t['text'],'point':center(t)} for t in texts if all_row and in_region(t,view,'setlist') and bounds['Width']*.59 < t['rect']['x'] < bounds['Width']*.80 and t['rect']['y'] > all_row['rect']['y']+15]
    if view['blockingDialog']:
        view['parameters'] = []
        view['objects'] = []
        view['selectedObject'] = None
    return view


def inspect_view(include_image=False):
    global LAST_VIEW
    LAST_VIEW = parse_view(native('inspect_ui', includeImage=include_image))
    return LAST_VIEW


def observe_until(predicate, seconds=3):
    deadline=time.monotonic()+seconds
    while True:
        view=inspect_view()
        require_ready(view)
        if predicate(view) or time.monotonic()>=deadline:
            return view


def public_view(view):
    return {**{k:v for k,v in view.items() if k != 'texts'},'visibleText':[t['text'] for t in view['texts']]}


def require_ready(view):
    if view.get('blockingDialog'):
        dialog=view['blockingDialog']
        raise ToolFailure(dialog['code'],dialog['message'],observation=view['observation'])


def click_at(point, view):
    return native('click', **point, observation=view['observation'])


def exact_text(view, text, region='window'):
    matches = [t for t in view['texts'] if normalize(t['text']) == normalize(text) and in_region(t,view,region)]
    if len(matches) != 1:
        raise ToolFailure('AMBIGUOUS_CONTROL' if matches else 'CONTROL_NOT_VISIBLE',
                          'Expected one exact visible text match.', text=text, matches=len(matches))
    return matches[0]


def parameter(view, key):
    require_ready(view)
    found = [p for p in view['parameters'] if p['id'] == normalize(key)]
    if len(found) != 1 or found[0].get('ambiguous'):
        raise ToolFailure('PARAMETER_NOT_VISIBLE', 'Parameter is absent or ambiguous in this view.', parameter=key,
                          available=[p['id'] for p in view['parameters']])
    return found[0]


def scroll_inspector(view, delta):
    # The inspector's left margin is outside its value widgets.
    native('scroll_hid', x=view['bounds']['X']+14,
           y=view['bounds']['Y']+view['bounds']['Height']*.65, deltaY=delta, observation=view['observation'])
    return inspect_view()


def inspector_signature(view):
    return tuple(sorted((t['text'], round(t['rect']['y']/6)) for t in view['texts'] if in_region(t,view,'inspector')))


def discover(scan=True):
    view = inspect_view()
    require_ready(view)
    known = {p['id']:p for p in view['parameters']}
    pages = 1
    if scan:
        view = scroll_inspector(view, 2000)
        known.update({p['id']:p for p in view['parameters']})
        for _ in range(12):
            previous = inspector_signature(view)
            view = scroll_inspector(view, -450)
            pages += 1
            known.update({p['id']:p for p in view['parameters']})
            if previous == inspector_signature(view): break
        view = scroll_inspector(view, 2000)
    return {'selectedObject':view['selectedObject'], 'parameters':list(known.values()),
            'pagesInspected':pages, 'observation':view['observation'],
            'coverage':'Recognized controls in expanded inspector sections and camera toolbar. No hidden scene API.'}


def same_value(control, requested):
    actual = control['value']
    if control['kind'] in ('number','slider','unresolved_slider'):
        if type(requested) not in (int,float): return False
        number = re.search(r'[+-]?\d+(?:[.,](\d+))?', control['display'])
        decimals = len(number[1]) if number and number[1] else 0
        return abs(actual - requested) <= max(.5 * 10**(-decimals),control.get('tolerance',0)) + 1e-8
    if control['kind'] == 'boolean': return type(requested) is bool and actual == requested
    return normalize(str(actual)) == normalize(str(requested))


def check_parameter_value(control, value):
    if control.get('available') is False:
        raise ToolFailure('EDITION_RESTRICTED',control['restriction'],parameter=control['id'])
    kind = control['kind']
    if kind in ('number','slider','unresolved_slider') and (type(value) not in (int,float) or not math.isfinite(value)):
        raise RPCError(-32602, control['id']+' requires a finite number')
    if kind == 'boolean' and type(value) is not bool:
        raise RPCError(-32602, control['id']+' requires a boolean')
    if kind == 'choice' and (not isinstance(value,str) or not value.strip()):
        raise RPCError(-32602, control['id']+' requires exact visible option text')
    if kind == 'unresolved_slider':
        raise ToolFailure('CONTROL_GEOMETRY_UNRESOLVED', 'Slider track could not be identified; no values changed.', parameter=control['id'])


def menu_options(view, control, baseline=None):
    patterns={'aperture':r'f/\d+(?:\.\d+)?','iso':r'(?:ISO\s*)?\d+',
              'white_balance':r'\d+\s*K','shutter_speed':r'(?:1/)?\d+(?:\.\d+)?\s*s',
              'aspect_ratio':r'\d+:\d+','lens':r'\d+(?:-\d+)?\s*mm','nd_filter':r'ND\s*\d+',
              'sensor':r'Full Frame|APS-C.*|Micro Four.*'}
    pattern=patterns.get(control['id'])
    if pattern:
        width = 120 if control['id'] in ('sensor','lens') else 55
        origin=control.get('valuePoint',control['point'])
        return [t for t in view['texts'] if re.fullmatch(pattern,t['text'],re.I) and t['screenY']>origin['y']+15 and abs(t['screenX']-origin['x'])<width]
    if baseline is None:return []
    return [t for t in view['texts'] if not any(normalize(t['text'])==normalize(old['text']) and abs(t['screenX']-old['screenX'])<8 and abs(t['screenY']-old['screenY'])<8 for old in baseline['texts'])]


def choices_for(key, view=None):
    view = view or inspect_view()
    control = parameter(view, key)
    if control['kind'] != 'choice': raise RPCError(-32602, 'Parameter is not a choice control')
    existing=menu_options(view,control)
    if len(existing)>1:return control,view,existing
    native('click',**control['point'],durationMs=750,observation=view['observation'])
    after=observe_until(lambda v:bool(menu_options(v,control,view)))
    options=menu_options(after,control,view)
    if not options:raise ToolFailure('MENU_NOT_OPEN','Chooser did not open; no option was selected.',parameter=key)
    return control,after,options


def close_chooser(control, opened, options):
    current=[t for t in options if normalize(t['text'])==normalize(str(control['value']))]
    if len(current)==1:
        click_at(center(current[0]),opened)
    else:
        click_at(center(exact_text(opened,'SETUP','toolbar')),opened)
    def closed(v):
        remaining=sum(any(normalize(t['text'])==normalize(o['text']) and abs(t['screenY']-o['screenY'])<8 and abs(t['screenX']-o['screenX'])<8 for t in v['texts']) for o in options)
        return remaining < max(1,len(options)//2)
    view=observe_until(closed)
    if not closed(view):
        native('click',**center(exact_text(view,'SETUP','toolbar')),durationMs=750,observation=view['observation'])
        view=observe_until(closed)
    if not closed(view):raise ToolFailure('MENU_STILL_OPEN','Options were read, but the chooser did not close.',options=[t['text'] for t in options],observation=view['observation'])
    if not same_value(parameter(view,control['id']),control['value']):
        raise ToolFailure('READBACK_MISMATCH','The chooser closed with a different value.',parameter=control['id'])
    return view


def set_choice(key, value, view=None):
    control, opened, options = choices_for(key, view)
    # A choice can remain at the old row; include it only when exactly requested.
    matches = [t for t in options if normalize(t['text']) == normalize(value)]
    if len(matches) != 1:
        raise ToolFailure('OPTION_NOT_VISIBLE', 'Exact option is absent or ambiguous; the menu remains open.',
                          parameter=key, requested=value, visibleOptions=[t['text'] for t in options], observation=opened['observation'])
    click_at(center(matches[0]), opened)
    after = observe_until(lambda v:any(p['id']==normalize(key) and same_value(p,value) for p in v['parameters']) and len(menu_options(v,control)) < 2)
    result = parameter(after,key)
    if not same_value(result,value):
        raise ToolFailure('READBACK_MISMATCH', 'Choice was clicked but the requested value was not read back.', parameter=key, requested=value, actual=result['value'])
    return after


SLIDER_CALIBRATION = {}


def set_slider(key, requested, view):
    control = parameter(view,key)
    if same_value(control, requested): return view
    geometry = control['slider']
    axis = 'y' if geometry['axis'] == 'vertical' else 'x'
    cache_key = (view['observation']['pid'], view['observation']['windowId'],
                 tuple(sorted(view['bounds'].items())), view['selectedObject'], key,
                 tuple((p['id'],str(p['value'])) for p in view['parameters'] if p['id'] in ('flash_head','variant')))
    calibration = SLIDER_CALIBRATION.get(cache_key)
    samples = []
    initial = (geometry['thumb'][axis],control['value'])
    trace = []
    for attempt in range(8):
        check_cancelled()
        control = parameter(view,key)
        geometry = control.get('slider')
        if not geometry: raise ToolFailure('CONTROL_GEOMETRY_UNRESOLVED','Slider track disappeared.',parameter=key)
        current, thumb = control['value'], geometry['thumb']
        if same_value(control, requested): return view
        lower, upper = sorted([geometry['minPoint'][axis],geometry['maxPoint'][axis]])
        below = [s for s in samples if s[1] < requested]
        above = [s for s in samples if s[1] > requested]
        if below and above:
            low,high=min(((lo,hi) for lo in below for hi in above),key=lambda pair:abs(pair[0][0]-pair[1][0]))
            target=low[0]+(high[0]-low[0])*(requested-low[1])/(high[1]-low[1])
        elif calibration:
            slope,offset=calibration
            target=(requested-offset)/slope
        elif samples and samples[-1][1] != initial[1] and abs(samples[-1][0]-initial[0])>.2:
            slope=(samples[-1][1]-initial[1])/(samples[-1][0]-initial[0])
            target=samples[-1][0]+(requested-samples[-1][1])/slope
        else:
            direction = (1 if requested > current else -1) * (-1 if axis=='y' else 1)
            target=thumb[axis]+direction*min(15,(upper-lower)*.15)
        target=max(lower,min(upper,target))
        destination=dict(thumb);destination[axis]=target
        via={}
        if abs(target-thumb[axis]) < 8:
            detour=dict(thumb)
            detour[axis]=thumb[axis]+12 if upper-thumb[axis]>=12 else thumb[axis]-12
            via={'viaX':detour['x'],'viaY':detour['y']}
        native('drag_hid',fromX=thumb['x'],fromY=thumb['y'],toX=destination['x'],toY=destination['y'],durationMs=1800,observation=view['observation'],**via)
        after=inspect_view()
        result=parameter(after,key)
        trace.append({'position':round(target,3),'value':result['value']})
        if samples and any(abs(target-x)<.1 and value==result['value'] for x,value in samples):
            raise ToolFailure('SLIDER_RESOLUTION_LIMIT','Requested value could not be reached at the current UI resolution.',parameter=key,requested=requested,actual=result['value'],adjustments=trace)
        samples.append((target,result['value']))
        pairs=[(x,y) for x,y in samples[:-1] if y != result['value'] and abs(x-target)>.2]
        if pairs:
            x,y=pairs[-1]
            slope=(result['value']-y)/(target-x)
            calibration=(slope,result['value']-slope*target)
            SLIDER_CALIBRATION[cache_key]=calibration
        if result['value']==current and len(samples)==1:
            raise ToolFailure('SLIDER_NO_CHANGE','Slider input did not change the value. No identical retry was sent.',parameter=key,actual=current)
        view=after
    if not same_value(parameter(view,key),requested):
        raise ToolFailure('READBACK_MISMATCH','Slider did not reach the requested value within eight measured adjustments.',parameter=key,requested=requested,actual=parameter(view,key)['value'],adjustments=trace)
    return view


def select_object(name, occurrence=None):
    view = inspect_view()
    require_ready(view)
    seen = set()
    if view['objects'] and not any(normalize(o['name'])==normalize(name) for o in view['objects']):
        native('scroll_hid',**view['objects'][0]['point'],deltaY=2000,observation=view['observation'])
        view=inspect_view()
    for _ in range(20):
        matches = [obj for obj in view['objects'] if normalize(obj['name']) == normalize(name)]
        if matches:
            if occurrence is None and len(matches) != 1:
                raise ToolFailure('AMBIGUOUS_OBJECT','Multiple rows have this name; specify occurrence.',name=name)
            index = (occurrence or 1)-1
            if index >= len(matches): raise ToolFailure('OBJECT_NOT_VISIBLE','Requested occurrence is not visible.',name=name)
            click_at(matches[index]['point'], view)
            after = observe_until(lambda v:bool(v.get('selectedObject')) and (normalize(v['selectedObject']) in normalize(name) or normalize(name) in normalize(v['selectedObject'])))
            # The inspector can use a shorter equipment title than the setlist.
            selected = normalize(after.get('selectedObject') or '')
            if not selected or not (selected in normalize(name) or normalize(name) in selected):
                raise ToolFailure('SELECTION_UNVERIFIED','The row was clicked but inspector selection could not be verified.', name=name, selected=after.get('selectedObject'))
            return after
        marker = tuple(obj['name'] for obj in view['objects'])
        if not marker or marker in seen: break
        seen.add(marker)
        row = view['objects'][-1]
        native('scroll_hid', **row['point'], deltaY=-320, observation=view['observation'])
        view = inspect_view()
    raise ToolFailure('OBJECT_NOT_FOUND','Object was not found in the visible/scrolled SETLIST.', name=name)


def set_parameters(values, target=None, expected=None):
    started = time.monotonic()
    values = {normalize(k):v for k,v in values.items()}
    expected = {normalize(k):v for k,v in (expected or {}).items()}
    if set(expected)-set(values): raise RPCError(-32602,'expected keys must also appear in values')
    view = select_object(target) if target else inspect_view()
    require_ready(view)
    visible = {p['id']:p for p in view['parameters'] if not p.get('ambiguous')}
    # Never start a partial update merely because one supplied name is unknown.
    if set(values)-set(visible):
        if (view.get('selectedObject') or '').startswith('Shot-'):
            raise ToolFailure('OBJECT_NOT_SELECTED','A timeline image is selected. Select a scene object first.')
        catalog = discover(True)
        available = {p['id']:p for p in catalog['parameters'] if not p.get('ambiguous')}
        missing = set(values)-set(available)
        if missing: raise ToolFailure('UNKNOWN_PARAMETER','No scene values changed: parameter was not found.',missing=sorted(missing),available=sorted(available))
        view = inspect_view()
    else: available = visible
    for key,value in values.items():
        check_parameter_value(available[key],value)
        if key in expected and not same_value(available[key], expected[key]):
            raise ToolFailure('PRECONDITION_FAILED','No scene values changed: current value differs from expected.',parameter=key,expected=expected[key],actual=available[key]['value'])
    before = {k:available[k]['value'] for k in values}
    completed, pending = {}, dict(values)
    scrolls = 0
    active_key = None
    try:
        while pending:
            check_cancelled()
            current = {p['id']:p for p in view['parameters'] if not p.get('ambiguous')}
            active = [k for k in pending if k in current]
            if not active:
                if scrolls >= 12: raise ToolFailure('PARAMETER_NOT_VISIBLE','Remaining controls were not found after scrolling.',remaining=list(pending))
                view = scroll_inspector(view,-450); scrolls+=1; continue
            unchanged = [k for k in active if same_value(current[k],pending[k])]
            for key in unchanged: completed[key]=current[key]['value']; pending.pop(key)
            # Equipment swaps and unlocking can alter the remaining controls.
            # Refresh their geometry before writing any transform or power.
            structural = next((k for k in ('light_shaper','variant','flash_head','flash_head_variant','sensor','lens','aspect_ratio') if k in pending and k in current),None)
            if 'target_lock' in pending and pending['target_lock'] is False and 'target_lock' in current:
                active_key='target_lock'
                click_at(current[active_key]['point'],view)
                view=observe_until(lambda v:not parameter(v,active_key)['value'])
                if parameter(view,active_key)['value']:
                    raise ToolFailure('READBACK_MISMATCH','Could not unlock the selected light.',parameter=active_key)
                completed[active_key]=False;pending.pop(active_key)
                continue
            if structural:
                active_key=structural
                view=set_choice(structural,pending[structural],view)
                completed[structural]=parameter(view,structural)['value'];pending.pop(structural)
                continue
            numbers = [k for k in active if k in pending and current[k]['kind']=='number']
            # Apply translation before rotation, regardless of JSON key order.
            # Updating a transform can recompute the displayed Euler angles.
            transform_order = {'position_x':0,'position_y':1,'height':2,'pitch':3,'roll':4,'yaw':5}
            numbers.sort(key=lambda k:(transform_order.get(k,6),current[k]['point']['y']))
            if numbers:
                active_key = numbers[0] if len(numbers)==1 else None
                actions = []
                for key in numbers:
                    actions.extend([{'command':'click',**current[key]['point']}, {'command':'keypress','key':'cmd+a'},
                                    {'command':'type_text','text':format(pending[key],'.12g')}, {'command':'keypress','key':'tab'}])
                native('batch', actions=actions, observation=view['observation'])
                view = observe_until(lambda v:all(any(p['id']==k and same_value(p,pending[k]) for p in v['parameters']) for k in numbers))
                mismatch = []
                for key in numbers:
                    result = parameter(view,key)
                    if same_value(result,pending[key]): completed[key]=result['value']; pending.pop(key)
                    else: mismatch.append({'parameter':key,'requested':pending[key],'actual':result['value']})
                if mismatch: raise ToolFailure('READBACK_MISMATCH','At least one requested number was not read back. No retry was sent.',mismatches=mismatch)
            for key in active:
                if key not in pending: continue
                active_key = key
                control = parameter(view,key)
                if control['kind']=='boolean':
                    click_at(control['point'],view)
                    view=observe_until(lambda v:same_value(parameter(v,key),pending[key]))
                    result=parameter(view,key)
                    if not same_value(result,pending[key]): raise ToolFailure('READBACK_MISMATCH','Toggle value was not verified.',parameter=key,actual=result['value'])
                elif control['kind']=='choice': view=set_choice(key,pending[key],view)
                elif control['kind']=='slider': view=set_slider(key,pending[key],view)
                else: raise ToolFailure('UNSUPPORTED_CONTROL','No setter for this control.',parameter=key)
                completed[key]=parameter(view,key)['value']; pending.pop(key)
        # Recheck related values which may have been recomputed by target locks.
        current = {p['id']:p for p in view['parameters']}
        changed_again = [k for k in completed if k in current and not same_value(current[k],values[k])]
        if changed_again: raise ToolFailure('DEPENDENT_VALUE_CHANGED','Other settings changed previously verified fields.',parameters=changed_again)
        return {'uiEffectVerified':True,'before':before,'after':completed,'requested':values,
                'tolerances':{k:available[k]['tolerance'] for k in values if 'tolerance' in available[k]},'selectedObject':view['selectedObject'],
                'elapsedSeconds':round(time.monotonic()-started,2),'observation':view['observation']}
    except ToolFailure as exc:
        if exc.code=='EDITION_RESTRICTED' and active_key:
            SESSION_RESTRICTIONS[(view['observation']['pid'],view['selectedObject'],active_key)]=str(exc)
            exc.details['blockedParameter']=active_key
        exc.details.update({'before':before,'verified':completed,'remaining':pending,'uiEffectVerified':False})
        raise


def menu_command(menu, item):
    view=inspect_view()
    click_at(center(exact_text(view,menu,'toolbar')),view)
    view=inspect_view()
    click_at(center(exact_text(view,item)),view)
    return inspect_view()


def project_title(view):
    return next((t['text'].split(':',1)[1].strip() for t in view['texts'] if t['text'].startswith('Project:')),None)


def wait_dialog(identifier, present=True, seconds=6):
    deadline=time.monotonic()+seconds
    while True:
        state=native('dialog_state')
        found=any(e['identifier']==identifier and e['enabled'] for e in state['elements'])
        if found == present: return state
        if time.monotonic()>=deadline:
            raise ToolFailure('DIALOG_NOT_READY','Native file dialog did not reach the expected state.',identifier=identifier,present=present)
        check_cancelled()
        time.sleep(.1)


def save_project(path, overwrite=False):
    destination=Path(path).expanduser()
    if not destination.is_absolute() or destination.suffix.lower()!='.set' or not destination.parent.is_dir():
        raise RPCError(-32602,'Use an absolute .set path with an existing parent directory')
    if destination.is_symlink() or (destination.exists() and not overwrite):
        raise ToolFailure('FILE_EXISTS','Destination exists or is a symbolic link; no save was started.')
    previous=destination.stat().st_mtime_ns if destination.exists() else None
    view=inspect_view()
    require_ready(view)
    native('focus')
    native('keypress',key='cmd+shift+s',transport='hid',observation=view['observation'])
    wait_dialog('saveAsNameTextField')
    native('dialog_action',identifier='saveAsNameTextField',value=destination.name)
    native('keypress',key='cmd+shift+g',transport='hid')
    wait_dialog('PathTextField')
    native('dialog_action',identifier='PathTextField',value=str(destination.parent))
    native('keypress',key='return',transport='hid')
    wait_dialog('PathTextField',present=False)
    native('dialog_action',identifier='OKButton')
    deadline=time.monotonic()+20
    last_file_state=None
    replacement_requested=False
    while time.monotonic()<deadline:
        check_cancelled()
        if destination.is_file() and destination.stat().st_size>0 and destination.stat().st_mtime_ns != previous:
            info=destination.stat()
            current_file_state=(info.st_mtime_ns,info.st_size)
            if current_file_state==last_file_state:
                view=inspect_view()
                if project_title(view) == destination.stem:
                    return {'path':str(destination),'bytes':info.st_size,'uiEffectVerified':True,'observation':view['observation']}
            last_file_state=current_file_state
        if overwrite and not replacement_requested:
            state=native('dialog_state')
            matches=[e for e in state['elements'] if e['identifier']=='ReplaceButton' and e['enabled']]
            if len(matches)==1:
                native('dialog_action',identifier='ReplaceButton')
                replacement_requested=True
                deadline=time.monotonic()+15
        event=getattr(LOCAL,'cancel_event',None)
        if event: event.wait(.25)
        else: time.sleep(.25)
    raise ToolFailure('SAVE_UNVERIFIED','Save did not produce a verified project file. Inspect the open dialog.',path=str(destination))


SCENE_KEYS={'undo':'cmd+z','redo':'cmd+shift+z','snapshot':'return','aim_at_model':'e',
            'toggle_solo':'s','toggle_light':'q','toggle_tripod':'w','focus_selection':'f',
            'swap_views':'t','toggle_library':'n','toggle_inspector':'b','mirror_selected':'m','open_pose_control':'p'}


def scene_command(action):
    if action=='snapshot':
        shot,view=take_snapshot()
        return {'action':action,'snapshot':shot,'uiEffectVerified':True,'view':public_view(view)}
    toggles={'toggle_solo':'solo','toggle_light':'light_on','toggle_tripod':'tripod_visible'}
    if action in toggles:
        key=toggles[action];view=inspect_view()
        return {'action':action,**set_parameters({key:not parameter(view,key)['value']})}
    view=inspect_view()
    require_ready(view)
    click_at(center(exact_text(view,'SETUP','toolbar')),view)
    # Clicking the active workspace clears text-entry focus without touching a scene object.
    native('keypress',key=SCENE_KEYS[action],transport='hid',observation=view['observation'])
    after=inspect_view()
    before={p['id']:p['value'] for p in view['parameters']}
    changes={p['id']:{'before':before[p['id']],'after':p['value']} for p in after['parameters'] if p['id'] in before and p['value']!=before[p['id']]}
    return {'action':action,'uiEffectVerified':bool(changes),'parameterChanges':changes,'view':public_view(after)}


def take_snapshot(view=None):
    view=view or inspect_view()
    require_ready(view)
    click_at(center(exact_text(view,'SETUP','toolbar')),view)
    view=inspect_view()
    if not any(t['text']=='Snap' for t in view['texts']):
        click_at(center(exact_text(view,'TIMELINE')),view)
        view=observe_until(lambda v:any(t['text']=='Snap' for t in v['texts']))
    label=exact_text(view,'Snap')
    point=center(label);point['y']-=34  # Camera icon directly above its label.
    old=view.get('selectedObject')
    native('click',**point,durationMs=750,observation=view['observation'])
    view=observe_until(lambda v:bool(v.get('selectedObject','')) and v['selectedObject'].startswith('Shot-') and v['selectedObject']!=old)
    shot=view.get('selectedObject') or ''
    if not shot.startswith('Shot-') or shot==old:
        raise ToolFailure('SNAPSHOT_UNVERIFIED','The app did not show a newly selected snapshot. No retry was sent.')
    return shot,view


def render(output_directory,wait_seconds=60):
    directory=Path(output_directory).expanduser()
    if not directory.is_absolute() or not directory.is_dir(): raise RPCError(-32602,'output_directory must be an existing absolute directory')
    view=inspect_view()
    require_ready(view)
    if directory.name != project_title(view): raise ToolFailure('PROJECT_MISMATCH','Output folder basename must match the active saved project title.')
    shot,view=take_snapshot(view)
    path=directory/(shot+'.jpg')
    previous=(path.stat().st_mtime_ns,path.stat().st_size) if path.is_file() else None
    click_at(center(exact_text(view,'VIEW','toolbar')),view)
    view=observe_until(lambda v:any(t['text']=='Render Shot' for t in v['texts']))
    click_at(center(exact_text(view,'Render Shot')),view)
    deadline=time.monotonic()+wait_seconds
    last=None
    while time.monotonic()<deadline:
        check_cancelled()
        current=(path.stat().st_mtime_ns,path.stat().st_size) if path.is_file() else None
        if current and current[1]>1024 and current!=previous and last==current:
            with path.open('rb') as handle:
                handle.seek(-2,2)
                complete=handle.read()==b'\xff\xd9'
            if complete:return {'completed':True,'uiEffectVerified':True,'snapshot':shot,'path':str(path),'bytes':current[1]}
        last=current
        event=getattr(LOCAL,'cancel_event',None)
        if event:event.wait(.5)
        else:time.sleep(.5)
    raise ToolFailure('RENDER_UNVERIFIED','The selected snapshot did not produce a completed JPEG before the deadline. The app may still be rendering.',completed=False,snapshot=shot,path=str(path))



def call_tool(name, args):
    validate_action(name, args)
    if sys.platform != 'darwin': return tool_result({'ok':False,'error':'This helper requires macOS 14 or later.'})
    if not HELPER.is_file(): return tool_result({'ok':False,'error':'Helper is not built. Run sh build.sh.'})
    if not OPERATION_LOCK.acquire(blocking=False): return tool_result({'ok':False,'code':'BUSY','error':'Another operation is running; re-observe before retrying.'})
    try:
        with helper_lock() as fd:
            LOCAL.lock_fd = fd
            LOCAL.deadline = time.monotonic()+120
            check_cancelled()
            if name == 'inspect_ui': detail=public_view(inspect_view(args.get('includeImage',False)))
            elif name == 'discover_parameters': detail=discover(args.get('scan',True))
            elif name == 'select_object': detail=public_view(select_object(args['name'],args.get('occurrence')))
            elif name == 'set_parameters': detail=set_parameters(**args)
            elif name == 'menu_command':
                detail=public_view(menu_command(**args)); detail['uiEffectVerified']=False
            elif name == 'save_project': detail=save_project(**args)
            elif name == 'render': detail=render(**args)
            elif name == 'scene_command': detail=scene_command(**args)
            elif name == 'configure_scene':
                completed=[]
                try:
                    for obj in args['objects']:
                        result=set_parameters(**obj)
                        completed.append({'target':obj['target'],**result})
                except ToolFailure as exc:
                    exc.details['completedObjects']=completed
                    exc.details['failedObjectIndex']=len(completed)
                    raise
                detail={'uiEffectVerified':True,'objects':completed}
            elif name == 'list_options':
                control, view, options=choices_for(args['parameter'])
                closed=close_chooser(control,view,options)
                detail={'parameter':control['id'],'current':control['value'],'options':[t['text'] for t in options],'observation':closed['observation'],'menuOpen':False}
            elif name == 'choose_option': detail=set_parameters({args['parameter']:args['value']})
            elif name == 'click_control':
                view=inspect_view()
                if args['observation'] != view['observation']:
                    old,new=args['observation'],view['observation']
                    if any(old[k]!=new[k] for k in ('pid','windowId','bounds')) or time.time()*1000-old['capturedAtMs']>180000:
                        raise ToolFailure('STALE_OBSERVATION','Re-observe before clicking.')
                click_at(center(exact_text(view,args['text'],args.get('region','window'))),view)
                detail=public_view(inspect_view())
                detail['uiEffectVerified']=False
            else:
                args = dict(args)
                if name in (*BATCH_NAMES[1:],'batch'):
                    observation=args.get('observation',LAST_OBSERVATION)
                    if observation is None: raise ToolFailure('OBSERVATION_REQUIRED','Call screenshot or inspect_ui before input, or pass its observation.')
                    args['observation']=observation
                detail=native(name,**args)
            image=detail.pop('imageBase64',None)
            data={'ok':True,'result':detail}
            result=tool_result(data)
            if image is not None:
                raw=base64.b64decode(image,validate=True)
                if len(raw)>20_000_000 or not raw.startswith(b'\x89PNG\r\n\x1a\n'): raise ValueError('Invalid PNG')
                result['content'].append({'type':'image','mimeType':'image/png','data':image})
            return result
    except ToolFailure as exc: return tool_result({'ok':False,'code':exc.code,'error':exc.message,**exc.details})
    except BlockingIOError: return tool_result({'ok':False,'code':'BUSY','error':'Another SetALight MCP operation is running.'})
    except (ValueError,OSError,KeyError,TypeError):
        return tool_result({'ok':False,'code':'HELPER_FAILED','error':'Helper failed or returned invalid output. Run --doctor; input may be partially applied.'})
    finally:
        LOCAL.lock_fd=None
        LOCAL.deadline=math.inf
        OPERATION_LOCK.release()

def error_response(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


class Session:
    def __init__(self):
        self.initialized = False

    def handle(self, request):
        if not isinstance(request, dict) or request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
            return error_response(None, -32600, "Invalid JSON-RPC request")
        # A notification must never trigger an input action or receive a response.
        if "id" not in request:
            return None
        request_id = request["id"]
        if type(request_id) not in (str, int):
            return error_response(None, -32600, "id must be a string or integer")
        try:
            method, params = request["method"], request.get("params", {})
            if not isinstance(params, dict):
                raise RPCError(-32602, "params must be an object")
            if method == "initialize":
                if self.initialized:
                    raise RPCError(-32600, "Session is already initialized")
                version = params.get("protocolVersion")
                if not isinstance(version, str) or not isinstance(params.get("capabilities"), dict) or not isinstance(params.get("clientInfo"), dict):
                    raise RPCError(-32602, "Invalid initialization parameters")
                self.initialized = True
                result = {"protocolVersion": version if version in PROTOCOLS else PROTOCOLS[0],
                          "capabilities": {"tools": {"listChanged": False}},
                          "serverInfo": {"name": "setalight-local-input", "version": VERSION}, "instructions": INSTRUCTIONS}
            elif method == "ping":
                result = {}
            elif not self.initialized:
                raise RPCError(-32002, "Initialize the server first")
            elif method == "tools/list":
                if params.get("cursor") not in (None, ""):
                    raise RPCError(-32602, "Unknown cursor; all tools are returned in one page")
                result = {"tools": TOOLS}
            elif method == "tools/call":
                result = call_tool(params.get("name"), params.get("arguments", {}))
            else:
                raise RPCError(-32601, "Method not found")
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except RPCError as exc:
            return error_response(request_id, exc.code, exc.message)
        except Exception:
            return error_response(request_id, -32603, "Internal server error")


def run_server(source=None, sink=None):
    source = source if source is not None else sys.stdin.buffer
    sink = sink if sink is not None else sys.stdout
    session = Session()
    output_lock = threading.Lock()
    active = None

    def emit(response):
        if response is not None:
            with output_lock:
                sink.write(json.dumps(response, ensure_ascii=True, allow_nan=False) + "\n")
                sink.flush()

    def work(request, event):
        LOCAL.cancel_event = event
        try:
            response = session.handle(request)
            if not event.is_set():
                emit(response)
        finally:
            LOCAL.cancel_event = None

    try:
        while True:
            line = source.readline(MAX_LINE + 1)
            if not line:
                break
            if len(line) > MAX_LINE:
                while not line.endswith(b"\n"):
                    line = source.readline(MAX_LINE + 1)
                    if not line: break
                emit(error_response(None, -32600, 'Request exceeds 1 MiB'))
                continue
            if not line.strip(): continue
            try:
                request = json_loads(line)
            except (ValueError, UnicodeError):
                emit(error_response(None, -32700, 'Parse error'))
                continue
            if isinstance(request, dict) and request.get('jsonrpc') == '2.0':
                method = request.get('method')
                if method == 'notifications/cancelled' and 'id' not in request:
                    params = request.get('params', {})
                    if isinstance(params, dict) and active and params.get('requestId') == active[0]:
                        active[1].set()
                    continue
                if method == 'tools/call' and type(request.get('id')) in (str, int) and session.initialized:
                    if active and active[2].is_alive():
                        emit(error_response(request['id'], -32001, 'Another tool is running; cancel or wait for it first.'))
                        continue
                    event = threading.Event()
                    worker = threading.Thread(target=work, args=(request,event), daemon=False)
                    active = (request['id'], event, worker)
                    worker.start()
                    continue
            emit(session.handle(request))
    finally:
        if active:
            active[1].set()
            active[2].join(timeout=5)


def client_config(client):
    executable = str(Path(sys.executable).resolve())
    script = str(ROOT / "server.py")
    if client == "claude-code":
        return shlex.join(["claude", "mcp", "add", "--transport", "stdio", "--scope", "user", "setalight", "--", executable, script])
    if client == "codex-cli":
        return shlex.join(["codex", "mcp", "add", "setalight", "--", executable, script])
    if client == "codex":
        return "\n".join([
            "[mcp_servers.setalight]",
            "command = " + json.dumps(executable, ensure_ascii=False),
            "args = " + json.dumps([script], ensure_ascii=False),
            "startup_timeout_sec = 10",
            "tool_timeout_sec = 150",
        ])
    if client == "claude-desktop":
        return json.dumps({"mcpServers": {"setalight": {"command": executable, "args": [script]}}}, indent=2)
    raise ValueError("Unknown MCP client")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--call", choices=BY_NAME, help="Call one tool; no MCP session required")
    modes.add_argument("--config", choices=("claude-desktop", "claude-code", "codex", "codex-cli"), help="Print configuration; does not change client settings")
    modes.add_argument("--doctor", action="store_true", help="Read-only platform/build/permission diagnostics")
    modes.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("--args", default="{}", help="Tool arguments as a JSON object")
    options = parser.parse_args()
    if options.config:
        print(client_config(options.config))
        return 0
    if options.call or options.doctor:
        try:
            result = call_tool(options.call or "status", json_loads(options.args) if options.call else {})
            print(json.dumps(result, ensure_ascii=True, indent=2))
            return int(result["isError"])
        except (RPCError, ValueError) as exc:
            print(str(exc), file=sys.stderr)
            return 2
    try:
        run_server()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
