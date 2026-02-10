#!/usr/bin/env python3
"""Cloud to Disk Backup - Ingress Web UI (v2.1)

Full dynamic configuration:
- Backup jobs: CRUD via /api/jobs (stored in /data/jobs.json)
- Cloud remotes: managed via direct rclone.conf editing (no RC API for config)
- Status, logs, triggers: unchanged from v1
"""

import json
import os
import re
import glob
import subprocess
import uuid
import urllib.request
import urllib.error
from collections import OrderedDict
from datetime import datetime
from flask import Flask, render_template, jsonify, request, Response

app = Flask(__name__,
            template_folder='/usr/local/bin/web/templates')

INGRESS_PATH = os.environ.get('INGRESS_PATH', '')
STATUS_DIR = os.environ.get('ADDON_STATUS_DIR', '/data/status')
DATA_DIR = os.environ.get('ADDON_DATA_DIR', '/data')
RCLONE_CONF = os.environ.get('ADDON_RCLONE_CONF', '/data/rclone.conf')
JOBS_FILE = os.environ.get('ADDON_JOBS_FILE', '/data/jobs.json')
RCLONE_RC_URL = 'http://127.0.0.1:5572'


# =========================================================================
# Helpers
# =========================================================================

def load_jobs():
    """Load backup jobs from /data/jobs.json."""
    try:
        with open(JOBS_FILE, 'r') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def save_jobs(jobs):
    """Save backup jobs to /data/jobs.json."""
    with open(JOBS_FILE, 'w') as f:
        json.dump(jobs, f, indent=2)


def rc_call(endpoint, params=None):
    """Call rclone RC API on localhost:5572."""
    url = f'{RCLONE_RC_URL}/{endpoint}'
    data = json.dumps(params or {}).encode('utf-8')
    req = urllib.request.Request(
        url, data=data,
        headers={'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', errors='replace')
        return {'error': f'RC error {e.code}: {body}'}
    except Exception as e:
        return {'error': str(e)}


# =========================================================================
# rclone.conf direct read/write (avoids RC API config/create issues)
# =========================================================================

def read_rclone_sections():
    """Read rclone.conf into OrderedDict: {name: {key: value, ...}}."""
    sections = OrderedDict()
    current = None
    try:
        with open(RCLONE_CONF, 'r') as f:
            for line in f:
                line = line.rstrip('\n\r')
                m = re.match(r'^\[(.+)\]$', line.strip())
                if m:
                    current = m.group(1)
                    sections[current] = OrderedDict()
                elif current is not None and '=' in line:
                    key, _, value = line.partition('=')
                    sections[current][key.strip()] = value.strip()
    except FileNotFoundError:
        pass
    return sections


def write_rclone_sections(sections):
    """Write OrderedDict back to rclone.conf."""
    with open(RCLONE_CONF, 'w') as f:
        first = True
        for name, params in sections.items():
            if not first:
                f.write('\n')
            first = False
            f.write(f'[{name}]\n')
            for key, value in params.items():
                f.write(f'{key} = {value}\n')


def graph_api_get(endpoint, access_token):
    """Call Microsoft Graph API."""
    url = f'https://graph.microsoft.com/v1.0{endpoint}'
    req = urllib.request.Request(url, headers={
        'Authorization': f'Bearer {access_token}',
        'Accept': 'application/json'
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8', errors='replace')
        return {'error': f'Graph API {e.code}: {body}'}
    except Exception as e:
        return {'error': str(e)}


def resolve_onedrive_drive_id(token_str, drive_type):
    """Auto-discover the drive_id from an OAuth token for OneDrive.

    Returns (drive_id, drive_type) or raises ValueError.
    """
    try:
        token_data = json.loads(token_str)
    except (json.JSONDecodeError, TypeError):
        raise ValueError('Invalid token JSON')

    access_token = token_data.get('access_token', '')
    if not access_token:
        raise ValueError('Token has no access_token')

    if drive_type in ('personal', 'business'):
        result = graph_api_get('/me/drive', access_token)
        if 'error' in result:
            raise ValueError(f'Could not query OneDrive: {result["error"]}')
        drive_id = result.get('id', '')
        if not drive_id:
            raise ValueError('No drive ID returned from Graph API')
        # Detect actual drive type from Graph response
        actual_type = result.get('driveType', drive_type)
        if actual_type == 'personal':
            return drive_id, 'personal'
        else:
            return drive_id, 'business'
    elif drive_type == 'documentLibrary':
        # SharePoint - list available drives
        result = graph_api_get('/me/drives', access_token)
        if 'error' in result:
            raise ValueError(f'Could not list drives: {result["error"]}')
        drives = result.get('value', [])
        if not drives:
            raise ValueError('No drives found')
        # Use the first document library drive
        for d in drives:
            if d.get('driveType') == 'documentLibrary':
                return d['id'], 'documentLibrary'
        # Fallback to first drive
        return drives[0]['id'], 'documentLibrary'
    else:
        raise ValueError(f'Unknown drive_type: {drive_type}')


def get_all_status():
    """Read status files for all accounts."""
    statuses = []
    if os.path.isdir(STATUS_DIR):
        for f in sorted(glob.glob(os.path.join(STATUS_DIR, 'status_*.json'))):
            try:
                with open(f, 'r') as fh:
                    statuses.append(json.load(fh))
            except (json.JSONDecodeError, IOError):
                name = os.path.basename(f).replace('status_', '').replace('.json', '')
                statuses.append({
                    'account': name, 'status': 'unknown',
                    'message': 'Status file unreadable'
                })
    return statuses


def get_disk_info(path):
    """Get disk usage for a path."""
    try:
        result = subprocess.run(
            ['df', '-BG', path], capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            lines = result.stdout.strip().split('\n')
            if len(lines) >= 2:
                parts = lines[1].split()
                return {
                    'path': path,
                    'total': parts[1] if len(parts) > 1 else '?',
                    'used': parts[2] if len(parts) > 2 else '?',
                    'available': parts[3] if len(parts) > 3 else '?',
                    'percent': parts[4] if len(parts) > 4 else '?'
                }
    except Exception:
        pass
    return {'path': path, 'total': '?', 'used': '?',
            'available': '?', 'percent': '?'}


def get_log_files():
    """Collect log files from all known backup paths + /data/logs."""
    logs = []
    seen = set()
    log_dirs = {os.path.join(DATA_DIR, 'logs')}
    for job in load_jobs():
        bp = job.get('backup_path', '')
        if bp:
            log_dirs.add(os.path.join(bp, 'logs'))
    for log_dir in log_dirs:
        for lf in glob.glob(os.path.join(log_dir, 'backup_*.log')):
            bn = os.path.basename(lf)
            if bn not in seen:
                seen.add(bn)
                logs.append({
                    'name': bn, 'path': lf,
                    'size': os.path.getsize(lf),
                    'modified': datetime.fromtimestamp(
                        os.path.getmtime(lf)).isoformat()
                })
    return sorted(logs, key=lambda x: x['modified'], reverse=True)[:30]


def find_log_path(filename):
    """Find absolute path for a log filename."""
    safe_name = os.path.basename(filename)
    for lf in get_log_files():
        if os.path.basename(lf['path']) == safe_name:
            return lf['path']
    return None


# =========================================================================
# Routes: Pages
# =========================================================================

@app.route('/')
def index():
    return render_template('index.html', ingress_path=INGRESS_PATH)


# =========================================================================
# Routes: Browse paths (dynamic disk/folder discovery)
# =========================================================================

@app.route('/api/browse', methods=['GET'])
def api_browse_paths():
    """List directories under a given path (default: /media).

    Query params:
        path  – base directory to scan (default /media)
        depth – how many levels deep (default 2, max 4)
    Returns a flat list of directories with disk usage info.
    """
    base = request.args.get('path', '/media')
    depth = min(int(request.args.get('depth', 2)), 4)

    # Security: only allow browsing under /media, /share, /backup, /data
    allowed = ('/media', '/share', '/backup', '/data')
    real_base = os.path.realpath(base)
    if not any(real_base.startswith(a) or real_base == a for a in allowed):
        return jsonify({'error': 'Path not allowed'}), 403

    entries = []
    try:
        result = subprocess.run(
            ['find', base, '-maxdepth', str(depth), '-type', 'd'],
            capture_output=True, text=True, timeout=5
        )
        dirs = [d.strip() for d in result.stdout.strip().split('\n')
                if d.strip() and d.strip() != base]
    except Exception:
        dirs = []

    # Add disk usage info for top-level mounts
    for d in sorted(dirs):
        entry = {'path': d, 'name': os.path.basename(d)}
        # Get disk usage for top-level paths (direct children of /media)
        rel_parts = os.path.relpath(d, base).split(os.sep)
        if len(rel_parts) == 1:
            # Top-level mount — include disk info
            entry['is_mount'] = True
            di = get_disk_info(d)
            entry['total'] = di.get('total', '?')
            entry['available'] = di.get('available', '?')
            entry['percent'] = di.get('percent', '?')
        else:
            entry['is_mount'] = False
        # Skip lost+found
        if os.path.basename(d) == 'lost+found':
            continue
        entries.append(entry)

    return jsonify({'base': base, 'entries': entries})


# =========================================================================
# Routes: Backup Jobs CRUD
# =========================================================================

@app.route('/api/jobs', methods=['GET'])
def api_get_jobs():
    return jsonify({'jobs': load_jobs()})


@app.route('/api/jobs', methods=['POST'])
def api_create_job():
    data = request.get_json()
    name = data.get('name', '').strip()
    remote_name = data.get('remote_name', '').strip()
    backup_path = data.get('backup_path', '').strip()

    if not name or not remote_name or not backup_path:
        return jsonify({'error': 'Name, remote, and backup path are required'}), 400

    jobs = load_jobs()
    if any(j['name'] == name for j in jobs):
        return jsonify({'error': f'Job "{name}" already exists'}), 400

    job = {
        'id': str(uuid.uuid4())[:8],
        'name': name,
        'cloud_provider': data.get('cloud_provider', 'onedrive'),
        'remote_name': remote_name,
        'backup_path': backup_path,
        'excludes': [e.strip() for e in data.get('excludes', []) if e.strip()],
        'schedule_time': data.get('schedule_time', '02:00'),
        'schedule_days': data.get('schedule_days', [0, 1, 2, 3, 4, 5, 6]),
        'enabled': data.get('enabled', True),
        'created': datetime.now().isoformat()
    }
    jobs.append(job)
    save_jobs(jobs)
    return jsonify({'success': True, 'job': job})


@app.route('/api/jobs/<job_id>', methods=['PUT'])
def api_update_job(job_id):
    data = request.get_json()
    jobs = load_jobs()
    for j in jobs:
        if j['id'] == job_id:
            for key in ['name', 'cloud_provider', 'remote_name',
                        'backup_path', 'enabled',
                        'schedule_time', 'schedule_days']:
                if key in data:
                    j[key] = data[key]
            if 'excludes' in data:
                j['excludes'] = [e.strip() for e in data['excludes']
                                 if e.strip()]
            save_jobs(jobs)
            return jsonify({'success': True, 'job': j})
    return jsonify({'error': 'Job not found'}), 404


@app.route('/api/jobs/<job_id>', methods=['DELETE'])
def api_delete_job(job_id):
    jobs = load_jobs()
    new_jobs = [j for j in jobs if j['id'] != job_id]
    if len(new_jobs) == len(jobs):
        return jsonify({'error': 'Job not found'}), 404
    save_jobs(new_jobs)
    return jsonify({'success': True})


# =========================================================================
# Routes: Cloud Remotes (direct rclone.conf read/write)
# =========================================================================

@app.route('/api/remotes', methods=['GET'])
def api_list_remotes():
    sections = read_rclone_sections()
    remotes = [{'name': name, 'type': params.get('type', '?')}
               for name, params in sections.items()]
    return jsonify({'remotes': remotes})


@app.route('/api/remotes/<name>/config', methods=['GET'])
def api_get_remote_config(name):
    """Get config for a single remote (tokens redacted)."""
    sections = read_rclone_sections()
    if name not in sections:
        return jsonify({'error': 'Remote not found'}), 404
    safe = {}
    for k, v in sections[name].items():
        if k in ('token', 'client_secret', 'secret_access_key', 'pass',
                 'password', 'app_key', 'app_secret'):
            safe[k] = '[REDACTED]'
        else:
            safe[k] = v
    return jsonify({'name': name, 'config': safe})


@app.route('/api/remotes', methods=['POST'])
def api_create_remote():
    """Create a new rclone remote by writing directly to rclone.conf."""
    data = request.get_json()
    name = data.get('name', '').strip()
    provider = data.get('provider', '').strip()

    if not name or not provider:
        return jsonify({'error': 'Name and provider are required'}), 400

    if not re.match(r'^[a-zA-Z0-9_-]+$', name):
        return jsonify({
            'error': 'Remote name may only contain letters, numbers, _ and -'
        }), 400

    provider_map = {
        'onedrive': 'onedrive',
        'gdrive': 'drive',
        'dropbox': 'dropbox',
        's3': 's3',
        'sftp': 'sftp',
        'webdav': 'webdav'
    }
    rclone_type = provider_map.get(provider, provider)

    sections = read_rclone_sections()
    if name in sections:
        return jsonify({'error': f'Remote "{name}" already exists'}), 400

    params = OrderedDict()
    params['type'] = rclone_type

    # OAuth token (OneDrive, Google Drive, Dropbox)
    token = data.get('token', '').strip()
    if token:
        params['token'] = token

    # OneDrive specific — auto-discover drive_id via Graph API
    if provider == 'onedrive':
        drive_type = data.get('drive_type', 'personal')
        params['drive_type'] = drive_type
        if token:
            try:
                drive_id, actual_type = resolve_onedrive_drive_id(
                    token, drive_type
                )
                params['drive_id'] = drive_id
                params['drive_type'] = actual_type
            except ValueError as e:
                return jsonify({
                    'error': f'OneDrive drive discovery failed: {e}'
                }), 400

    # Google Drive specific
    if provider == 'gdrive':
        root_folder_id = data.get('root_folder_id', '').strip()
        if root_folder_id:
            params['root_folder_id'] = root_folder_id

    # S3 specific
    if provider == 's3':
        s3_provider = data.get('s3_provider', 'AWS').strip()
        params['provider'] = s3_provider
        for key in ('access_key_id', 'secret_access_key', 'region',
                    'endpoint', 'acl'):
            val = data.get(key, '').strip()
            if val:
                params[key] = val

    # SFTP specific
    if provider == 'sftp':
        for key in ('host', 'port', 'user', 'pass', 'key_file'):
            val = data.get(key, '').strip()
            if val:
                params[key] = val

    # WebDAV specific
    if provider == 'webdav':
        for key in ('url', 'vendor', 'user', 'pass'):
            val = data.get(key, '').strip()
            if val:
                params[key] = val

    sections[name] = params
    write_rclone_sections(sections)

    return jsonify({
        'success': True,
        'message': f'Remote "{name}" ({rclone_type}) created successfully'
    })


@app.route('/api/remotes/<name>', methods=['PUT'])
def api_update_remote(name):
    """Update an existing remote's config parameters."""
    data = request.get_json()
    sections = read_rclone_sections()
    if name not in sections:
        return jsonify({'error': f'Remote "{name}" not found'}), 404

    updates = data.get('config', {})
    for k, v in updates.items():
        v = str(v).strip()
        if v:
            sections[name][k] = v
        elif k in sections[name] and k != 'type':
            del sections[name][k]

    write_rclone_sections(sections)
    return jsonify({'success': True, 'message': f'Remote "{name}" updated'})


@app.route('/api/remotes/<name>', methods=['DELETE'])
def api_delete_remote(name):
    sections = read_rclone_sections()
    if name not in sections:
        return jsonify({'error': f'Remote "{name}" not found'}), 404
    del sections[name]
    write_rclone_sections(sections)
    return jsonify({'success': True})


@app.route('/api/remotes/<name>/test', methods=['POST'])
def api_test_remote(name):
    """Test connectivity to a remote via rclone about."""
    try:
        result = subprocess.run(
            ['rclone', 'about', f'{name}:', '--config', RCLONE_CONF, '--json'],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            return jsonify({'success': True, 'info': json.loads(result.stdout)})
        return jsonify({'success': False, 'error': result.stderr.strip()}), 400
    except subprocess.TimeoutExpired:
        return jsonify({'success': False, 'error': 'Connection timeout'}), 408
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 500


# =========================================================================
# Routes: rclone Config File (advanced)
# =========================================================================

@app.route('/api/rclone-config', methods=['GET'])
def api_get_rclone_config():
    """Get rclone.conf content with tokens redacted."""
    try:
        with open(RCLONE_CONF, 'r') as f:
            content = f.read()
        redacted = re.sub(r'(token\s*=\s*).*', r'\1[REDACTED]', content)
        redacted = re.sub(r'(client_secret\s*=\s*).*', r'\1[REDACTED]', redacted)
        return jsonify({'content': redacted})
    except FileNotFoundError:
        return jsonify({'content': ''})


@app.route('/api/rclone-config', methods=['POST'])
def api_upload_rclone_config():
    """Upload/replace rclone.conf content."""
    data = request.get_json()
    content = data.get('content', '')
    if not content.strip():
        return jsonify({'error': 'Config content is empty'}), 400
    try:
        # Backup existing config
        if os.path.exists(RCLONE_CONF):
            ts = datetime.now().strftime('%Y%m%d_%H%M%S')
            with open(RCLONE_CONF, 'r') as f:
                with open(f'{RCLONE_CONF}.bak.{ts}', 'w') as bf:
                    bf.write(f.read())
        with open(RCLONE_CONF, 'w') as f:
            f.write(content)
        return jsonify({'success': True, 'message': 'rclone config saved. '
                        'Restart the add-on for changes to take effect.'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# =========================================================================
# Routes: Status
# =========================================================================

@app.route('/api/status')
def api_status():
    jobs = load_jobs()
    disks = {}
    for job in jobs:
        bp = job.get('backup_path', '')
        if bp and bp not in disks:
            disks[bp] = get_disk_info(bp)
    return jsonify({
        'accounts': get_all_status(),
        'disks': list(disks.values()),
        'timestamp': datetime.now().isoformat()
    })


# =========================================================================
# Routes: Logs
# =========================================================================

@app.route('/api/logs')
def api_logs():
    return jsonify({'logs': get_log_files()})


@app.route('/api/logs/<path:filename>')
def api_log_content(filename):
    lines = int(request.args.get('lines', 200))
    filepath = find_log_path(filename)
    if not filepath:
        return jsonify({'error': 'Log not found'}), 404
    try:
        result = subprocess.run(
            ['tail', f'-n{lines}', filepath],
            capture_output=True, text=True, timeout=5
        )
        return jsonify({'content': result.stdout, 'filename': filename})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/logs/<path:filename>/stream')
def api_log_stream(filename):
    filepath = find_log_path(filename)
    if not filepath:
        return jsonify({'error': 'Log not found'}), 404

    def generate():
        proc = subprocess.Popen(
            ['tail', '-f', filepath],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        try:
            while True:
                line = proc.stdout.readline()
                if line:
                    yield (f"data: "
                           f"{line.decode('utf-8', errors='replace').rstrip()}"
                           f"\n\n")
        except GeneratorExit:
            proc.kill()

    return Response(generate(), mimetype='text/event-stream',
                    headers={'Cache-Control': 'no-cache',
                             'X-Accel-Buffering': 'no'})


# =========================================================================
# Routes: Trigger Backup
# =========================================================================

@app.route('/api/trigger', methods=['POST'])
def api_trigger_backup():
    data = request.get_json()
    job_name = data.get('name', '').strip()
    if not job_name:
        return jsonify({'error': 'Job name required'}), 400
    # Verify job exists
    jobs = load_jobs()
    if not any(j['name'] == job_name for j in jobs):
        return jsonify({'error': f'Job "{job_name}" not found'}), 404
    trigger_file = os.path.join(DATA_DIR, f'trigger_{job_name}')
    try:
        with open(trigger_file, 'w') as f:
            f.write(datetime.now().isoformat())
        return jsonify({
            'success': True,
            'message': f'Backup triggered for "{job_name}"'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# =========================================================================
# Main
# =========================================================================

if __name__ == '__main__':
    port = int(os.environ.get('ADDON_WEB_PORT', 8099))
    app.run(host='0.0.0.0', port=port, debug=False)
