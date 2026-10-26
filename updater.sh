#!/usr/bin/env bash
# Moodle Updater v2.0. Single-file deployment; PHP is already required by Moodle.
# PHP snippets deliberately prevent shell expansion of PHP's $variables.
# shellcheck disable=SC2016
set -Eeuo pipefail
umask 077

ASSUME_YES=false
ALLOW_UNSTABLE=false
SKIP_WEBROOT_UPDATE=false
SKIP_RESTART=false
DRY_RUN=false
CRON_PAUSED=false
BACKUP_MODE=copy
BACKUP_ROOT=/var/backups/moodle
WEB_USER=
PHP_BIN=${PHP_BIN:-php}
PRESERVE_PATHS=()
FPM_SERVICES=()
POSITIONAL_ARGS=()
WORK_DIR=
STAGE_DIR=
BACKUP_DIR=
LOCK_DIR=
DB_AUTH_FILE=
MOODLE_PATH=
DATA_PATH=
OLD_CODE=
PHASE=preflight
CODE_SWAPPED=false
OLD_MOVED=false
MAINTENANCE_CHANGED=false
SUCCESS=false
WEB_CHANGED=false
WEB_SERVICE=
INITIAL_CLI_MAINTENANCE=false
CRON_SAVED=()

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
error() { log "ERROR: $*"; }
die() { error "$*"; exit 1; }
usage() {
    cat <<'HELP'
Moodle Updater v2.0
Usage: bash updater.sh [options] <moodle_code> <moodledata> [version|latest]

  -y, --yes                 Do not prompt (all checks still apply)
      --dry-run             Download and validate; do not change the installation
      --backup-dir DIR      Persistent backup parent (default /var/backups/moodle)
      --backup-mode MODE    copy (default) or hardlink (immutable filedir only)
      --web-user USER       PHP/web server user (default: config.php owner)
      --fpm-service UNIT    PHP-FPM service used by this site; repeat if needed
                            (default: running service matching CLI PHP version)
      --preserve-path PATH  Preserve an extra non-core path relative to the old
                            Moodle webroot; repeat for multiple paths
      --cron-paused         Cron is already paused externally (systemd/cron.d/etc.)
      --allow-unstable      Explicitly allow prerelease tags or development branches
      --skip-webroot-update Keep web server configuration; verify it manually
      --no-restart          Keep CLI maintenance and cron paused after migration;
                            operator must restart web/PHP workers before reopening
  -h, --help                Show this help

Examples:
  sudo bash updater.sh --dry-run /var/www/moodle /var/lib/moodledata 5.2
  sudo bash updater.sh --yes /var/www/moodle /var/lib/moodledata 5.2.4

PHP/database package upgrades are deliberately separate from this tool.
Hardlink backups protect against update-time deletion, not disk failure or
in-place changes. Backups are not automatically deleted.
HELP
}
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -y|--yes|--non-interactive) ASSUME_YES=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --allow-unstable|--allow-dev) ALLOW_UNSTABLE=true; shift ;;
            --skip-webroot-update) SKIP_WEBROOT_UPDATE=true; shift ;;
            --no-restart) SKIP_RESTART=true; shift ;;
            --cron-paused) CRON_PAUSED=true; shift ;;
            --backup-dir|--backup-mode|--web-user|--preserve-path|--fpm-service)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "Missing value for $1"
                case "$1" in
                    --backup-dir) BACKUP_ROOT=$2 ;;
                    --backup-mode) BACKUP_MODE=$2 ;;
                    --web-user) WEB_USER=$2 ;;
                    --preserve-path) PRESERVE_PATHS+=("$2") ;;
                    --fpm-service)
                        [[ "$2" =~ ^[a-zA-Z0-9@_.:-]+\.service$ && "$2" != -* ]] || die "Invalid FPM service name"
                        FPM_SERVICES+=("$2") ;;
                esac
                shift 2 ;;
            --allow-system-changes)
                die "--allow-system-changes was removed. Upgrade PHP/database packages separately, then rerun --dry-run." ;;
            --) shift; POSITIONAL_ARGS+=("$@"); break ;;
            -*) die "Unknown option: $1" ;;
            *) POSITIONAL_ARGS+=("$1"); shift ;;
        esac
    done
    [[ "$BACKUP_MODE" == copy || "$BACKUP_MODE" == hardlink ]] || die "Invalid backup mode: $BACKUP_MODE"
}
ask_yes_no() {
    [[ "$ASSUME_YES" == true ]] && return 0
    local answer
    read -r -p "$1 [y/N]: " answer || return 1
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]]
}
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
php_helper() { "$PHP_BIN" "$WORK_DIR/helper.php" "$@"; }
as_web() { runuser -u "$WEB_USER" -- "$PHP_BIN" -d max_input_vars=5000 "$@"; }
json_value() { "$PHP_BIN" -r '$v=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR); foreach(explode(".",$argv[2]) as $k){$v=$v[$k]??null;} if(is_bool($v))echo $v?"true":"false";elseif(is_scalar($v))echo $v;elseif($v!==null)echo json_encode($v);' "$1" "$2"; }

# The embedded helper keeps the downloaded updater self-contained. All credentials
# stay in private files; neither shell arguments nor progress logs contain them.
write_helper() {
    cat > "$WORK_DIR/helper.php" <<'PHP'
<?php
declare(strict_types=1);
function fail(string $s): never {fwrite(STDERR,"ERROR: $s\n"); exit(1);}
function inside(string $p,string $root): bool {return $p===$root || str_starts_with($p,$root.'/');}
function versionfile(string $root): string {return is_file("$root/public/version.php")?"$root/public/version.php":"$root/version.php";}
function metadata(string $file,bool $plugin=false): array {
    if(!defined('MOODLE_INTERNAL'))define('MOODLE_INTERNAL',true);
    foreach(['MATURITY_ALPHA'=>50,'MATURITY_BETA'=>100,'MATURITY_RC'=>150,'MATURITY_STABLE'=>200,'ANY_VERSION'=>'any'] as $k=>$v){if(!defined($k))define($k,$v);}
    return (static function() use($file,$plugin){
        $version=$release=$branch=$maturity=null; $p=new stdClass(); $pvar=&$p;
        if($plugin){$plugin=$pvar; include $file; return (array)$plugin;}
        include $file; return compact('version','release','branch','maturity');
    })();
}
function cfg(string $code): void {
    global $CFG,$DB;
    if(!defined('CLI_SCRIPT'))define('CLI_SCRIPT',true);
    require "$code/config.php";
}
function validpath(string $rel): bool {return $rel!=='' && $rel[0]!=='/' && !preg_match('~(^|/)(\.\.?)(/|$)|[\x00-\x1f]~',$rel);}
function copytree(string $src,string $dst): void {
    if(is_link($src))fail("Symlinks in preserved paths require manual review: $src");
    if(is_dir($src)){
        if(!is_dir($dst)&&!mkdir($dst,0755,true))fail("Cannot create $dst");
        foreach(new DirectoryIterator($src) as $f){if(!$f->isDot()&&!in_array($f->getFilename(),['.git','.svn','.hg'],true))copytree($f->getPathname(),$dst.'/'.$f->getFilename());}
    }else{
        if(!is_dir(dirname($dst))&&!mkdir(dirname($dst),0755,true))fail('Cannot create parent');
        if(!copy($src,$dst))fail("Cannot copy $src");
        chmod($dst,fileperms($src)&0777);
    }
}
function resolve_target(array $tags,string $requested,bool $allow,array $branches): array {
    $stable=array_values(array_filter($tags,fn($t)=>preg_match('/^v\d+\.\d+\.\d+$/',$t)));
    usort($stable,fn($a,$b)=>version_compare(substr($b,1),substr($a,1)));
    if($requested==='latest')$requested=isset($stable[0])?substr($stable[0],1):'';
    if(preg_match('/^\d+\.\d+$/',$requested)){
        foreach($stable as $tag){if(str_starts_with($tag,'v'.$requested.'.')){$requested=substr($tag,1); break;}}
    }
    if(in_array('v'.$requested,$tags,true)){
        $unstable=!preg_match('/^\d+\.\d+\.\d+$/',$requested);
        if($unstable&&!$allow)fail('Prereleases require --allow-unstable');
        return ['ref'=>'refs/tags/v'.$requested,'label'=>$requested,'unstable'=>$unstable];
    }
    if($allow&&in_array($requested,$branches,true))return ['ref'=>'refs/heads/'.$requested,'label'=>$requested,'unstable'=>true];
    fail("Unknown release '$requested'. Missing patch versions never fall back to another branch. For development use --allow-unstable and an explicit branch name.");
}
function rewrite_webroot(string $text,string $old,string $new,string $kind): string {
    // Match the entire directive path: /moodle/public and /moodle2 must not match /moodle.
    $path='(?:"'.preg_quote($old,'~').'/?"|\x27'.preg_quote($old,'~').'/?\x27|'.preg_quote($old,'~').'/?)(?=[\s;>]|$)';
    if($kind==='apache'){
        $text=preg_replace_callback('~(^[\t ]*DocumentRoot[\t ]+)'.$path.'([\t ]*(?:\#.*)?$)~m',fn($m)=>$m[1].'"'.$new.'"'.$m[2],$text);
        return preg_replace_callback('~(<Directory[\t ]+)'.$path.'([\t ]*>)~',fn($m)=>$m[1].'"'.$new.'"'.$m[2],$text);
    }
    return preg_replace_callback('~(^[\t ]*root[\t ]+)'.$path.'([\t ]*;)~m',fn($m)=>$m[1].'"'.$new.'"'.$m[2],$text);
}
try {
$cmd=$argv[1]??'';
switch($cmd){
case 'resolve':
    $tags=json_decode(file_get_contents($argv[2]),true,512,JSON_THROW_ON_ERROR);
    $names=array_column($tags,'name');
    $branches=json_decode(file_get_contents($argv[3]),true,512,JSON_THROW_ON_ERROR);
    echo json_encode(resolve_target($names,$argv[4],$argv[5]==='true',array_column($branches,'name')),JSON_THROW_ON_ERROR);break;
case 'metadata': echo json_encode(metadata(versionfile($argv[2])),JSON_THROW_ON_ERROR);break;
case 'inspect':
    cfg($argv[2]);
    $server=(string)$DB->get_field_sql('SELECT VERSION()');
    if(!preg_match('/\d+\.\d+(?:\.\d+)?/',$server,$n))fail('Cannot determine actual database server version');
    $vendor=$DB->get_dbfamily();
    if($vendor==='mysql')$vendor=($CFG->dbtype==='mariadb'||stripos($server,'mariadb')!==false)?'mariadb':'mysql';
    if(!in_array($vendor,['mysql','mariadb','postgres'],true))fail('Supported database families: MariaDB, MySQL, PostgreSQL');
    $plugins=[];
    foreach(core_plugin_manager::instance()->get_plugins() as $group){foreach($group as $p){if(!$p->is_standard()){
        $root=$p->rootdir?realpath($p->rootdir):false;
        if($root&&!inside($root,$CFG->dirroot))fail('Plugin outside Moodle code tree: '.$p->component);
        $plugins[]=['component'=>$p->component,'relative'=>$root?substr($root,strlen($CFG->dirroot)+1):null,'status'=>$p->get_status()];
    }}}
    $counts=[];foreach(['user','course','course_modules','files'] as $table)$counts[$table]=$DB->count_records($table);
    $size=$vendor==='postgres'?$DB->get_field_sql('SELECT pg_database_size(current_database())'):$DB->get_field_sql('SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema=DATABASE()');
    echo json_encode(['release'=>$CFG->release,'build'=>$CFG->version,'branch'=>$CFG->branch,'dirroot'=>$CFG->dirroot,'dataroot'=>realpath($CFG->dataroot),'wwwroot'=>$CFG->wwwroot,'dbvendor'=>$vendor,'dbversion'=>$n[0],'dbbytes'=>(int)$size,'plugins'=>$plugins,'counts'=>$counts,'maintenance'=>(bool)get_config('core','maintenance_enabled')],JSON_THROW_ON_ERROR);break;
case 'requirements':
    $current=json_decode(file_get_contents($argv[2]),true,512,JSON_THROW_ON_ERROR);
    $root=$argv[3];$meta=metadata(versionfile($root));
    if(!$meta['version']||!$meta['branch']||!$meta['release'])fail('Invalid Moodle version metadata');
    if($meta['maturity']!==200&&$argv[4]!=='true')fail('Archive is not a stable Moodle release');
    if((float)$meta['version']<(float)$current['build'])fail('Refusing a build downgrade');
    $xmlpath=(is_dir("$root/public")?"$root/public":"$root").'/admin/environment.xml';
    $xml=simplexml_load_file($xmlpath);if(!$xml)fail('Missing or invalid target environment.xml');
    if(!preg_match('/^(\d+\.\d+)/',$meta['release'],$v))fail('Invalid target release');
    $match=$xml->xpath('/COMPATIBILITY_MATRIX/MOODLE[@version="'.$v[1].'"]');
    if(count($match)!==1)fail('No exact environment requirements for target '.$v[1]);$env=$match[0];
    if((string)$env['requires']!==''&&version_compare($current['release'],(string)$env['requires'],'<'))fail('An intermediate Moodle upgrade to '.(string)$env['requires'].' is required');
    $minphp=(string)$env->PHP['version'];
    if(!$minphp||version_compare(PHP_VERSION,$minphp,'<')||PHP_INT_SIZE<8)fail('Target requires 64-bit PHP '.$minphp.' or later');
    $vendors=$env->xpath('DATABASE/VENDOR[@name="'.$current['dbvendor'].'"]');
    if(count($vendors)!==1)fail('Database is not supported by the target release');
    $required=(string)$vendors[0]['version'];
    if(version_compare($current['dbversion'],$required,'<'))fail('Target requires '.$current['dbvendor'].' '.$required.'; actual server is '.$current['dbversion'].'. Upgrade the database separately.');
    foreach($env->PHP_EXTENSIONS->PHP_EXTENSION as $ext){
        if((string)$ext['level']==='required'&&!extension_loaded((string)$ext['name']))fail('Required PHP extension missing: '.(string)$ext['name']);
    }
    echo 'Target requirements passed: PHP '.$minphp.', '.$current['dbvendor'].' '.$required."\n";break;
case 'preserve':
    $current=json_decode(file_get_contents($argv[2]),true,512,JSON_THROW_ON_ERROR);
    $target=$argv[3];$web=is_dir("$target/public")?"$target/public":$target;$meta=metadata(versionfile($target));
    $paths=[];
    foreach($current['plugins'] as $p){
        if($p['relative']===null){fwrite(STDERR,'WARNING: Already missing plugin: '.$p['component']."\n");continue;}
        $rel=$p['relative'];if(!validpath($rel))fail('Invalid plugin path');
        $pm=metadata($current['dirroot'].'/'.$rel.'/version.php',true);
        if(isset($pm['requires'])&&(float)$pm['requires']>(float)$meta['version'])fail('Plugin requires a newer Moodle: '.$p['component']);
        if(isset($pm['supported'])&&((int)$meta['branch']<(int)$pm['supported'][0]||(int)$meta['branch']>(int)$pm['supported'][1]))fail('Plugin does not declare support for target branch: '.$p['component']);
        $paths[]=$rel;
    }
    foreach(array_slice($argv,4) as $rel){if(!validpath($rel)||$rel==='config.php')fail('Invalid preserved path');$paths[]=$rel;}
    // Parent plugins include their subplugins; do not copy descendants twice.
    usort($paths,fn($a,$b)=>strlen($a)<=>strlen($b));$done=[];
    foreach(array_unique($paths) as $rel){
        foreach($done as $parent){if(inside($rel,$parent))continue 2;}
        $src=$current['dirroot'].'/'.$rel;$dst=$web.'/'.$rel;
        if(file_exists($dst)||is_link($dst))fail('Preserved path would overwrite target core code: '.$rel);
        if(!file_exists($src))fail('Preserved path does not exist: '.$rel);
        copytree($src,$dst);$done[]=$rel;echo 'Preserved '.$rel."\n";
    }break;
case 'db-auth':
    cfg($argv[2]);$out=$argv[3];$mode=$argv[4];
    $host=$CFG->dbhost??'localhost';$port=$CFG->dboptions['dbport']??$CFG->dbport??($mode==='postgres'?'5432':'3306');
    if($mode==='postgres'){
        $escape=fn($s)=>str_replace(['\\',':'],['\\\\','\\:'],(string)$s);
        $passhost=str_starts_with((string)$host,'/')?'localhost':$host;
        $pgpass=implode(':',array_map($escape,[$passhost,$port,$CFG->dbname,$CFG->dbuser,$CFG->dbpass]))."\n";
        if(preg_match('/[\r\n]/',(string)$CFG->dbpass))fail('Unsupported newline in PostgreSQL password');
        if(file_put_contents($out,$pgpass)===false)fail('Cannot write credentials');
    }else{
        $quote=fn($s)=>'"'.str_replace(['\\','"',"\n","\r"],['\\\\','\\"','\\n','\\r'],(string)$s).'"';
        $auth="[client]\nhost=".$quote($host)."\nport=".$quote($port)."\nuser=".$quote($CFG->dbuser)."\npassword=".$quote($CFG->dbpass)."\n";
        if(!empty($CFG->dboptions['dbsocket'])&&is_string($CFG->dboptions['dbsocket']))$auth.='socket='.$quote($CFG->dboptions['dbsocket'])."\n";
        if(file_put_contents($out,$auth)===false)fail('Cannot write credentials');
    }
    chmod($out,0600);
    echo json_encode(['host'=>$host,'port'=>$port,'user'=>$CFG->dbuser,'name'=>$CFG->dbname],JSON_THROW_ON_ERROR);break;
case 'cron-pids':
    cfg($argv[2]);$active=$DB->count_records_select('task_scheduled','timestarted > 0')+$DB->count_records_select('task_adhoc','timestarted > 0');
    foreach(glob('/proc/[0-9]*/cmdline') as $f){
        $cmd=@file_get_contents($f);if(!$cmd)continue;$args=explode("\0",$cmd);$exe=@readlink(dirname($f).'/exe');
        if(!$exe||!preg_match('~/php(?:\d+(?:\.\d+)*)?(?: \(deleted\))?$~',$exe))continue;
        if(!in_array($argv[2].'/admin/cli/cron.php',$args,true)&&!in_array($argv[2].'/public/admin/cli/cron.php',$args,true))continue;
        $pid=basename(dirname($f));$idle=!$active&&trim((string)@file_get_contents(dirname($f).'/wchan'))==='hrtimer_nanosleep';
        echo $pid.' '.($idle?'idle':'busy')."\n";
    }break;
case 'webroot':
    $old=$argv[2];$new=$argv[3];$out=$argv[4];$count=0;
    foreach(['apache'=>['/etc/apache2/sites-available/*','/etc/apache2/conf-available/*','/etc/httpd/conf/httpd.conf','/etc/httpd/conf.d/*'],'nginx'=>['/etc/nginx/sites-available/*','/etc/nginx/conf.d/*','/etc/nginx/nginx.conf']] as $kind=>$patterns){
        foreach($patterns as $pattern){foreach(glob($pattern) as $file){
            if(!is_file($file)||is_link($file)||preg_match('/\.(bak|backup)(\.|$)/',basename($file)))continue;
            $s=file_get_contents($file);$next=rewrite_webroot($s,$old,$new,$kind);if($next===$s)continue;
            $dest=$out.$file;if(!is_dir(dirname($dest)))mkdir(dirname($dest),0700,true);
            if(!copy($file,$dest)||file_put_contents($file,$next)===false)fail('Cannot update '.$file);
            echo "Updated $file\n";$count++;
        }}
    }
    file_put_contents($out.'/changed',(string)$count);break;
case 'bootstrap':
    $file=$argv[2];$public=$argv[3]==='true';$s=file_get_contents($file);
    if($public){
        $pattern='~^([\t ]*require(?:_once)?[\t ]*\(?[^;\r\n]*[\x27\"]/?(?:public/)?lib/setup\.php[\x27\"][^;\r\n]*;)~m';
        // Common config uses __DIR__ . '/lib/setup.php'. Only this bootstrap is rewritten.
        $replacement="\$CFG->dirroot = __DIR__ . '/public';\n\$CFG->libdir = \$CFG->dirroot . '/lib';\nrequire_once(\$CFG->libdir . '/setup.php');";
        $next=preg_replace_callback($pattern,fn()=>$replacement,$s,1,$n);
        if($n!==1)fail('Unrecognized config.php bootstrap; adapt it manually before upgrading to public/');
        if(file_put_contents($file,$next)===false)fail('Cannot prepare config.php');
    }break;
case 'canonical':
    $path=$argv[2];$suffix=[];
    while(!file_exists($path)){if($path==='/'||$path==='.'||$path==='')fail('Invalid path');$suffix[]=basename($path);$path=dirname($path);}
    $path=realpath($path);if($path===false)fail('Cannot resolve path');
    foreach(array_reverse($suffix) as $part){if($part==='..')$path=dirname($path);elseif($part!=='.')$path=rtrim($path,'/').'/'.$part;}
    echo $path;break;
case 'archive-types':
    foreach(file($argv[2],FILE_IGNORE_NEW_LINES) as $line){if(!in_array($line[0]??'', ['-','d'],true))fail('Archive links and special files are not allowed');}break;
case 'archive-list':
    $root=null;foreach(file($argv[2],FILE_IGNORE_NEW_LINES) as $p){
        if(!$p||$p[0]==='/'||preg_match('~(^|/)\.\.(/|$)|[\x00-\x1f]~',$p))fail('Unsafe archive entry');
        $first=explode('/',$p)[0];if($root!==null&&$root!==$first)fail('Multiple archive roots');$root=$first;
    }if(!$root)fail('Empty archive');break;
case 'rewrite-test': echo rewrite_webroot(file_get_contents($argv[2]),$argv[3],$argv[4],$argv[5]);break;
case 'hash': echo hash_file('sha256',$argv[2]);break;
default: fail('Unknown helper command');
}
}catch(Throwable $e){fail($e->getMessage());}
PHP
}

fetch_json() {
    curl --fail --silent --show-error --location --retry 2 --connect-timeout 20 --max-time 90 "$1" -o "$2"
    "$PHP_BIN" -r 'json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);' "$2"
}
resolve_moodle_target() {
    local requested=$1
    fetch_json 'https://api.github.com/repos/moodle/moodle/tags?per_page=100' "$WORK_DIR/tags.json"
    # An exact older release may be outside GitHub's first page of tags.
    if [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(beta|rc[0-9]+))?$ ]] &&
        ! "$PHP_BIN" -r '$tags=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);exit(in_array("v".$argv[2],array_column($tags,"name"),true)?0:1);' "$WORK_DIR/tags.json" "$requested"; then
        fetch_json "https://api.github.com/repos/moodle/moodle/git/ref/tags/v$requested" "$WORK_DIR/exact-tag.json"
        "$PHP_BIN" -r '$r=json_decode(file_get_contents($argv[2]),true,512,JSON_THROW_ON_ERROR);if(($r["ref"]??"")!=="refs/tags/v".$argv[3])exit(1);$t=json_decode(file_get_contents($argv[1]),true,512,JSON_THROW_ON_ERROR);$t[]=["name"=>"v".$argv[3]];file_put_contents($argv[1],json_encode($t,JSON_THROW_ON_ERROR));' "$WORK_DIR/tags.json" "$WORK_DIR/exact-tag.json" "$requested"
    fi
    printf '[]' > "$WORK_DIR/branches.json"
    if [[ "$ALLOW_UNSTABLE" == true ]]; then
        fetch_json 'https://api.github.com/repos/moodle/moodle/branches?per_page=100' "$WORK_DIR/branches.json"
    fi
    php_helper resolve "$WORK_DIR/tags.json" "$WORK_DIR/branches.json" "$requested" "$ALLOW_UNSTABLE" > "$WORK_DIR/target.json"
}
prepare_target() {
    local ref
    ref=$(json_value "$WORK_DIR/target.json" ref)
    log "Downloading $(json_value "$WORK_DIR/target.json" label) before maintenance"
    curl --fail --silent --show-error --location --retry 2 --connect-timeout 20 --max-time 600 \
        "https://github.com/moodle/moodle/archive/$ref.tar.gz" -o "$WORK_DIR/moodle.tar.gz"
    tar -tzf "$WORK_DIR/moodle.tar.gz" > "$WORK_DIR/archive-list.txt"
    php_helper archive-list "$WORK_DIR/archive-list.txt"
    tar -tvzf "$WORK_DIR/moodle.tar.gz" > "$WORK_DIR/archive-types.txt"
    php_helper archive-types "$WORK_DIR/archive-types.txt"
    mkdir "$STAGE_DIR/new"
    tar --no-same-owner -xzf "$WORK_DIR/moodle.tar.gz" --strip-components=1 -C "$STAGE_DIR/new"
    [[ -f "$STAGE_DIR/new/admin/cli/upgrade.php" ]] || die "Archive has no Moodle CLI upgrader"
    # Do not carry archive symlinks into a privileged filesystem operation.
    [[ -z "$(find "$STAGE_DIR/new" -type l -print -quit)" ]] || die "Archive symlinks require manual review"
    php_helper metadata "$STAGE_DIR/new" > "$WORK_DIR/target-metadata.json"
}

check_disk_space() {
    local data_kb code_kb db_kb backup_kb available parent_available filedir_kb=0
    data_kb=$(du -sk "$DATA_PATH" | awk '{print $1}')
    code_kb=$(du -sk "$MOODLE_PATH" | awk '{print $1}')
    db_kb=$(( $(json_value "$WORK_DIR/current.json" dbbytes) / 1024 + 1 ))
    if [[ "$BACKUP_MODE" == hardlink && -d "$DATA_PATH/filedir" ]]; then
        [[ "$(stat -c %d "$DATA_PATH/filedir")" == "$(stat -c %d "$BACKUP_ROOT")" ]] || die "Hardlink backup needs the same filesystem as filedir"
        filedir_kb=$(du -sk "$DATA_PATH/filedir" | awk '{print $1}')
    fi
    backup_kb=$((data_kb - filedir_kb + code_kb + db_kb * 2 + 524288))
    available=$(df -Pk "$BACKUP_ROOT" | awk 'END {print $4}')
    parent_available=$(df -Pk "$(dirname "$MOODLE_PATH")" | awk 'END {print $4}')
    (( available >= backup_kb )) || die "Insufficient backup space: need about $((backup_kb/1024)) MiB, have $((available/1024)) MiB. Choose another --backup-dir or explicitly choose --backup-mode hardlink."
    (( parent_available >= 262144 )) || die "Less than 256 MiB free on the code filesystem after staging"
    log "Backup space check passed ($BACKUP_MODE; allowance $((backup_kb/1024)) MiB)"
}
check_staging_space() {
    local code_kb available work_available needed
    code_kb=$(du -sk "$MOODLE_PATH" | awk '{print $1}')
    available=$(df -Pk "$(dirname "$MOODLE_PATH")" | awk 'END {print $4}')
    work_available=$(df -Pk "$WORK_DIR" | awk 'END {print $4}')
    needed=$((code_kb * 2 + 524288))
    (( available >= needed && work_available >= 262144 )) || die "Insufficient space to download/extract a release safely before maintenance"
}
validate_cron_sources() {
    [[ "$CRON_PAUSED" == true ]] && return 0
    local file
    for file in /etc/crontab /etc/cron.d/*; do
        [[ -f "$file" ]] || continue
        if grep -v '^[[:space:]]*#' "$file" | grep -F "$MOODLE_PATH" | grep -q 'admin/cli/cron.php'; then
            die "Moodle cron found in $file. Pause it externally, then pass --cron-paused."
        fi
    done
    # systemd timers and remote schedulers cannot reliably be discovered here.
    require_command crontab
}
pause_cron() {
    [[ "$CRON_PAUSED" == true ]] && return 0
    local user before after
    for user in root "$WEB_USER"; do
        [[ -f "$WORK_DIR/cron-$user.before" ]] && continue
        before="$WORK_DIR/cron-$user.before"; after="$WORK_DIR/cron-$user.paused"
        if ! crontab -u "$user" -l > "$before" 2> "$WORK_DIR/cron-read.err"; then
            if grep -qi 'no crontab' "$WORK_DIR/cron-read.err"; then rm -f "$before"; continue; fi
            die "Cannot read crontab for $user"
        fi
        "$PHP_BIN" -r '$s=file($argv[1]);foreach($s as &$l){if(!preg_match("/^\\s*#/",$l)&&str_contains($l,$argv[3])&&str_contains($l,"admin/cli/cron.php"))$l="# moodle-updater paused: ".$l;}unset($l);file_put_contents($argv[2],implode("",$s));' "$before" "$after" "$MOODLE_PATH"
        if ! cmp -s "$before" "$after"; then
            # Record before mutating, so a failed crontab write can also be recovered.
            CRON_SAVED+=("$user")
            crontab -u "$user" "$after"
            log "Paused Moodle cron for $user"
        fi
    done
}
restore_cron() {
    local user status=0
    for user in "${CRON_SAVED[@]}"; do
        # Remove only our markers, retaining unrelated concurrent crontab edits.
        if crontab -u "$user" -l > "$WORK_DIR/cron-$user.current" &&
            "$PHP_BIN" -r '$s=file_get_contents($argv[1]);$s=preg_replace("/^# moodle-updater paused: /m","",$s);file_put_contents($argv[2],$s);' "$WORK_DIR/cron-$user.current" "$WORK_DIR/cron-$user.restored" &&
            crontab -u "$user" "$WORK_DIR/cron-$user.restored"; then
            log "Restored cron for $user"
        else error "Could not restore cron for $user"; status=1; fi
    done
    return "$status"
}
re_pause_cron() {
    local user
    for user in "${CRON_SAVED[@]}"; do
        crontab -u "$user" -l > "$WORK_DIR/cron-$user.recovery-current" || return 1
        "$PHP_BIN" -r '$s=file($argv[1]);foreach($s as &$l){if(!preg_match("/^\\s*#/",$l)&&str_contains($l,$argv[3])&&str_contains($l,"admin/cli/cron.php"))$l="# moodle-updater paused: ".$l;}unset($l);file_put_contents($argv[2],implode("",$s));' "$WORK_DIR/cron-$user.recovery-current" "$WORK_DIR/cron-$user.recovery-paused" "$MOODLE_PATH" || return 1
        crontab -u "$user" "$WORK_DIR/cron-$user.recovery-paused" || return 1
    done
}
wait_for_cron() {
    local attempt pid state count
    for ((attempt=0;attempt<24;attempt++)); do
        php_helper cron-pids "$MOODLE_PATH" > "$WORK_DIR/cron-pids"
        count=0
        while read -r pid state; do
            [[ -n "$pid" ]] || continue
            count=$((count+1))
            if [[ "$state" == idle ]]; then kill -TERM "$pid" 2>/dev/null || true; fi
        done < "$WORK_DIR/cron-pids"
        [[ "$count" == 0 ]] && return 0
        (( attempt % 6 != 0 )) || log "Waiting for existing Moodle cron workers"
        sleep 5
    done
    die "Cron is still active after 120 seconds; code was not replaced"
}
enable_maintenance_mode() {
    if [[ ! -f "$DATA_PATH/climaintenance.html" ]]; then
        MAINTENANCE_CHANGED=true
        as_web "$MOODLE_PATH/admin/cli/maintenance.php" --enable
    fi
    [[ -f "$DATA_PATH/climaintenance.html" ]] || die "CLI maintenance file was not created"
}
disable_maintenance_mode() {
    [[ "$MAINTENANCE_CHANGED" == true ]] || return 0
    as_web "$MOODLE_PATH/admin/cli/maintenance.php" --disable
    [[ ! -e "$DATA_PATH/climaintenance.html" ]] || die "CLI maintenance is still enabled"
}
backup_database() {
    local vendor name host port user
    vendor=$(json_value "$WORK_DIR/current.json" dbvendor)
    DB_AUTH_FILE="$WORK_DIR/db-auth"
    php_helper db-auth "$MOODLE_PATH" "$DB_AUTH_FILE" "$vendor" > "$WORK_DIR/db-connection.json"
    name=$(json_value "$WORK_DIR/db-connection.json" name)
    [[ "$name" != -* && -n "$name" ]] || die "Invalid database name"
    if [[ "$vendor" == postgres ]]; then
        host=$(json_value "$WORK_DIR/db-connection.json" host)
        port=$(json_value "$WORK_DIR/db-connection.json" port)
        user=$(json_value "$WORK_DIR/db-connection.json" user)
        PGPASSFILE="$DB_AUTH_FILE" pg_dump --no-password --host="$host" --port="$port" --username="$user" --format=custom --file="$BACKUP_DIR/database.dump" -- "$name"
        pg_restore --list "$BACKUP_DIR/database.dump" > "$BACKUP_DIR/database.contents"
    else
        mysqldump --defaults-file="$DB_AUTH_FILE" --single-transaction --routines --triggers --quick --hex-blob -- "$name" > "$BACKUP_DIR/database.sql"
        [[ -s "$BACKUP_DIR/database.sql" ]] || die "Database dump is empty"
    fi
    rm -f "$DB_AUTH_FILE"; DB_AUTH_FILE=
}
create_backup() {
    log "Creating complete backup in $BACKUP_DIR"
    cp -a "$MOODLE_PATH" "$BACKUP_DIR/code"
    mkdir "$BACKUP_DIR/moodledata"
    if [[ "$BACKUP_MODE" == hardlink && -d "$DATA_PATH/filedir" ]]; then
        cp -al "$DATA_PATH/filedir" "$BACKUP_DIR/moodledata/filedir"
        tar --exclude='./filedir' -C "$DATA_PATH" -cf - . | tar -C "$BACKUP_DIR/moodledata" -xf -
    else
        cp -a "$DATA_PATH/." "$BACKUP_DIR/moodledata/"
    fi
    backup_database
    cp "$WORK_DIR/current.json" "$BACKUP_DIR/before.json"
    cp "$WORK_DIR/target-metadata.json" "$BACKUP_DIR/target.json"
    cp "$WORK_DIR/target.json" "$BACKUP_DIR/source.json"
    printf '%s  moodle.tar.gz\n' "$(php_helper hash "$WORK_DIR/moodle.tar.gz")" > "$BACKUP_DIR/source.sha256"
    local file
    for file in "$WORK_DIR"/cron-*.before; do [[ ! -f "$file" ]] || cp "$file" "$BACKUP_DIR/"; done
    printf 'code=%s\ndata=%s\nbackup_mode=%s\ninitial_cli_maintenance=%s\n' "$MOODLE_PATH" "$DATA_PATH" "$BACKUP_MODE" "$INITIAL_CLI_MAINTENANCE" > "$BACKUP_DIR/paths.txt"
    for file in "$BACKUP_DIR"/database.sql "$BACKUP_DIR"/database.dump; do
        [[ ! -f "$file" ]] || printf '%s  %s\n' "$(php_helper hash "$file")" "$(basename "$file")" > "$BACKUP_DIR/database.sha256"
    done
    printf 'Complete code, moodledata and database backup\n' > "$BACKUP_DIR/BACKUP_COMPLETE"
}
web_configtest() {
    case "$WEB_SERVICE" in
        apache2) apache2ctl configtest ;;
        httpd) httpd -t ;;
        nginx) nginx -t ;;
        *) die "Cannot determine active Apache/Nginx service" ;;
    esac
}
update_webroot_for_public_dir() {
    [[ "$SKIP_WEBROOT_UPDATE" == true || ! -d "$MOODLE_PATH/public" ]] && return 0
    mkdir -p "$BACKUP_DIR/webserver"
    # Mark before modifying so partial configuration changes are also restored.
    WEB_CHANGED=true
    php_helper webroot "$MOODLE_PATH" "$MOODLE_PATH/public" "$BACKUP_DIR/webserver"
    if [[ "$(json_value "$WORK_DIR/current.json" dirroot)" == "$MOODLE_PATH" && "$(cat "$BACKUP_DIR/webserver/changed")" == 0 ]]; then
        die "No matching webroot directive found. Configure public/ manually and use --skip-webroot-update."
    fi
    web_configtest
}
restart_workers() {
    web_configtest
    systemctl restart "$WEB_SERVICE"
    systemctl is-active --quiet "$WEB_SERVICE"
    local unit
    # Restart only this site's selected PHP services, not every pool on the host.
    for unit in "${FPM_SERVICES[@]}"; do
        systemctl restart "$unit"
        systemctl is-active --quiet "$unit"
    done
}
restore_web_configs() {
    [[ "$WEB_CHANGED" == true && -d "$BACKUP_DIR/webserver" ]] || return 0
    local file rel
    while IFS= read -r -d '' file; do
        rel=${file#"$BACKUP_DIR/webserver"}
        [[ "$rel" == /etc/* ]] || continue
        cp -p "$file" "$rel" || return 1
    done < <(find "$BACKUP_DIR/webserver/etc" -type f -print0)
}
cleanup() {
    local status=$?
    trap - EXIT INT TERM HUP
    set +e
    [[ -z "$WORK_DIR" ]] || chmod 700 "$WORK_DIR"
    [[ -z "$DB_AUTH_FILE" ]] || rm -f "$DB_AUTH_FILE"
    if [[ "$SUCCESS" != true && "$PHASE" != preflight ]]; then
        if [[ "$PHASE" == migrating || "$PHASE" == verifying || "$PHASE" == awaiting-restart ]]; then
            # Never undo a potentially committed schema migration automatically.
            if [[ ! -e "$DATA_PATH/climaintenance.html" ]]; then
                printf '<h1>Maintenance</h1><p>Update recovery is required.</p>\n' > "$DATA_PATH/climaintenance.html"
                chmod 644 "$DATA_PATH/climaintenance.html"
            fi
            re_pause_cron || error "Cannot re-pause cron; inspect scheduler state"
            error "New code, maintenance and paused cron are retained until recovery/restart is complete."
            error "Restore code AND database together from $BACKUP_DIR, or repair and finish the upgrade."
            error "Private state/logs: $WORK_DIR"
            [[ "$PHASE" == awaiting-restart ]] || status=1
        else
            local recovered=true
            if [[ "$CODE_SWAPPED" == true ]]; then
                mv "$MOODLE_PATH" "$STAGE_DIR/failed-code" && mv "$OLD_CODE" "$MOODLE_PATH" || recovered=false
            elif [[ "$OLD_MOVED" == true ]]; then
                mv "$OLD_CODE" "$MOODLE_PATH" || recovered=false
            fi
            restore_web_configs || recovered=false
            if [[ "$recovered" == true ]]; then
                if [[ "$OLD_MOVED" == true ]]; then restart_workers || recovered=false; fi
                if [[ "$recovered" == true ]]; then
                    disable_maintenance_mode || recovered=false
                    restore_cron || recovered=false
                fi
            fi
            if [[ "$recovered" != true ]]; then error "Recovery incomplete; inspect $WORK_DIR and $BACKUP_DIR"; status=1; fi
        fi
    fi
    # Keep private working state on failure for diagnosis and cron recovery.
    if [[ "$SUCCESS" == true || "$PHASE" == preflight ]]; then
        [[ -z "$STAGE_DIR" ]] || rm -rf -- "$STAGE_DIR"
        [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    fi
    [[ -z "$LOCK_DIR" ]] || rmdir "$LOCK_DIR" 2>/dev/null
    exit "$status"
}

main() {
    parse_args "$@"
    [[ ${#POSITIONAL_ARGS[@]} -ge 2 && ${#POSITIONAL_ARGS[@]} -le 3 ]] || { usage >&2; exit 1; }
    [[ $EUID == 0 ]] || die "Run as root (CLI upgrades themselves run as the web user)"
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "Bash 4.4 or later is required"
    local cmd requested code_parent target_public target_release web_group owner config_group unit
    for cmd in "$PHP_BIN" curl tar find cp mv du df stat runuser systemctl mktemp; do require_command "$cmd"; done
    "$PHP_BIN" -r 'exit(version_compare(PHP_VERSION,"8.1",">=")?0:1);' || die "The updater requires PHP 8.1 or later"
    "$PHP_BIN" -r 'exit(extension_loaded("simplexml")?0:1);' || die "PHP SimpleXML is required"
    [[ ! -L "${POSITIONAL_ARGS[0]}" ]] || die "Pass the real code directory, not a symlink"
    MOODLE_PATH=$(cd "${POSITIONAL_ARGS[0]}" && pwd -P)
    DATA_PATH=$(cd "${POSITIONAL_ARGS[1]}" && pwd -P)
    [[ -f "$MOODLE_PATH/config.php" ]] || die "config.php not found"
    [[ "$MOODLE_PATH" != / && "$DATA_PATH" != / ]] || die "Root paths are not allowed"
    [[ "$DATA_PATH/" != "$MOODLE_PATH/"* && "$MOODLE_PATH/" != "$DATA_PATH/"* ]] || die "Code and moodledata must be separate, non-nested directories"
    code_parent=$(dirname "$MOODLE_PATH")
    [[ "$(stat -c %d "$MOODLE_PATH")" == "$(stat -c %d "$code_parent")" ]] || die "Code mount points cannot be swapped atomically"
    LOCK_DIR="$code_parent/.moodle-updater-$(basename "$MOODLE_PATH").lock"
    mkdir "$LOCK_DIR" 2>/dev/null || { LOCK_DIR=; die "Another updater is running (or a stale lock needs review)"; }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    WORK_DIR=$(mktemp -d /var/tmp/moodle-updater.XXXXXX)
    STAGE_DIR=$(mktemp -d "$code_parent/.moodle-updater-stage.XXXXXX")
    write_helper
    owner=$(stat -c %U "$MOODLE_PATH/config.php")
    config_group=$(stat -c %G "$MOODLE_PATH/config.php")
    if [[ -z "$WEB_USER" && "$owner" == root && "$config_group" != root ]] &&
        id "$config_group" >/dev/null 2>&1 && [[ "$(id -gn "$config_group")" == "$config_group" ]]; then
        WEB_USER=$config_group
    fi
    WEB_USER=${WEB_USER:-$owner}
    [[ "$WEB_USER" != root ]] || die "config.php is owned by root; specify --web-user explicitly"
    id "$WEB_USER" >/dev/null || die "Unknown web user"
    web_group=$(id -gn "$WEB_USER")
    runuser -u "$WEB_USER" -- test -r "$MOODLE_PATH/config.php" || die "The web user cannot read config.php"
    # Reading Moodle bootstrap can create cache files: use its own service user.
    chmod 711 "$WORK_DIR"
    chmod 644 "$WORK_DIR/helper.php"
    runuser -u "$WEB_USER" -- "$PHP_BIN" "$WORK_DIR/helper.php" inspect "$MOODLE_PATH" > "$WORK_DIR/current.json"
    chmod 700 "$WORK_DIR"
    [[ "$(json_value "$WORK_DIR/current.json" dataroot)" == "$DATA_PATH" ]] || die "Supplied moodledata does not match config.php"
    if [[ -d "$MOODLE_PATH/.git" ]]; then
        require_command git
        if ! git -c safe.directory="$MOODLE_PATH" -C "$MOODLE_PATH" diff --quiet ||
            ! git -c safe.directory="$MOODLE_PATH" -C "$MOODLE_PATH" diff --cached --quiet; then
            die "Tracked core changes require manual review"
        fi
    fi
    for cmd in apache2 httpd nginx; do
        if systemctl is-active --quiet "$cmd"; then
            [[ -z "$WEB_SERVICE" ]] || die "Multiple active web servers; configure the deployment manually"
            WEB_SERVICE=$cmd
        fi
    done
    if [[ ${#FPM_SERVICES[@]} == 0 ]]; then
        unit="php$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION,".",PHP_MINOR_VERSION;')-fpm.service"
        if systemctl is-active --quiet "$unit"; then FPM_SERVICES+=("$unit")
        elif systemctl is-active --quiet php-fpm.service; then FPM_SERVICES+=(php-fpm.service); fi
    fi
    for unit in "${FPM_SERVICES[@]}"; do
        systemctl is-active --quiet "$unit" || die "FPM service is not active: $unit"
    done
    if [[ "$WEB_SERVICE" == nginx && ${#FPM_SERVICES[@]} == 0 ]]; then
        die "No PHP-FPM service detected; pass this site's --fpm-service UNIT explicitly"
    fi
    web_configtest
    requested=${POSITIONAL_ARGS[2]:-latest}
    resolve_moodle_target "$requested"
    check_staging_space
    prepare_target
    php_helper requirements "$WORK_DIR/current.json" "$STAGE_DIR/new" "$ALLOW_UNSTABLE"
    if [[ "$(json_value "$WORK_DIR/target-metadata.json" version)" == "$(json_value "$WORK_DIR/current.json" build)" ]]; then
        log "Installed build already matches the target; no changes needed"
        SUCCESS=true; return 0
    fi
    php_helper preserve "$WORK_DIR/current.json" "$STAGE_DIR/new" "${PRESERVE_PATHS[@]}"
    cp -p "$MOODLE_PATH/config.php" "$STAGE_DIR/new/config.php"
    target_public=false
    [[ ! -f "$STAGE_DIR/new/public/config.php" ]] || target_public=true
    php_helper bootstrap "$STAGE_DIR/new/config.php" "$target_public"
    case "$(json_value "$WORK_DIR/current.json" dbvendor)" in
        postgres) require_command pg_dump; require_command pg_restore ;;
        *) require_command mysqldump ;;
    esac
    [[ "$BACKUP_ROOT" == /* ]] || die "--backup-dir must be absolute"
    BACKUP_ROOT=$(php_helper canonical "$BACKUP_ROOT")
    [[ "$BACKUP_ROOT/" != "$MOODLE_PATH/"* && "$BACKUP_ROOT/" != "$DATA_PATH/"* ]] || die "Backups must be outside code and moodledata"
    [[ "$MOODLE_PATH/" != "$BACKUP_ROOT/"* && "$DATA_PATH/" != "$BACKUP_ROOT/"* ]] || die "Backup parent may not contain code or moodledata"
    mkdir -p "$BACKUP_ROOT"
    check_disk_space
    validate_cron_sources
    target_release=$(json_value "$WORK_DIR/target-metadata.json" release)
    log "Plan: $(json_value "$WORK_DIR/current.json" release) -> $target_release; web user $WEB_USER"
    if [[ "$DRY_RUN" == true ]]; then log "Dry run passed. No code, database, maintenance, cron or web server settings changed."; SUCCESS=true; return 0; fi
    ask_yes_no "Update Moodle to $target_release with a $BACKUP_MODE backup?" || { log "Cancelled"; SUCCESS=true; return 0; }
    BACKUP_DIR=$(mktemp -d "$BACKUP_ROOT/$(basename "$MOODLE_PATH")-$(date +%Y%m%d_%H%M%S).XXXXXX")
    if [[ -f "$DATA_PATH/climaintenance.html" ]]; then
        INITIAL_CLI_MAINTENANCE=true
        cp -p "$DATA_PATH/climaintenance.html" "$WORK_DIR/original-maintenance.html"
    fi
    PHASE=quiescing
    pause_cron
    enable_maintenance_mode
    wait_for_cron
    PHASE=backing-up
    create_backup
    # Retain the invocation and all non-secret diagnostics with the backup.
    cp "$0" "$BACKUP_DIR/updater.sh"
    PHASE=installing
    chown -R "root:$web_group" "$STAGE_DIR/new"
    find "$STAGE_DIR/new" -type d -exec chmod 755 {} +
    find "$STAGE_DIR/new" -type f -exec chmod u=rwX,go=rX {} +
    chmod 640 "$STAGE_DIR/new/config.php"
    OLD_CODE="$STAGE_DIR/old"
    mv "$MOODLE_PATH" "$OLD_CODE"; OLD_MOVED=true
    mv "$STAGE_DIR/new" "$MOODLE_PATH"; CODE_SWAPPED=true
    update_webroot_for_public_dir
    # From this point onward, a failed command may have committed DB changes.
    PHASE=migrating
    local upgrade_args=(--non-interactive)
    [[ "$(json_value "$WORK_DIR/target.json" unstable)" != true ]] || upgrade_args+=(--allow-unstable)
    log "Running Moodle database upgrade as $WEB_USER; log: $BACKUP_DIR/upgrade.log"
    as_web "$MOODLE_PATH/admin/cli/upgrade.php" "${upgrade_args[@]}" > "$BACKUP_DIR/upgrade.log" 2>&1
    PHASE=verifying
    as_web "$MOODLE_PATH/admin/cli/purge_caches.php" >> "$BACKUP_DIR/upgrade.log" 2>&1
    as_web "$MOODLE_PATH/admin/cli/upgrade.php" --is-pending >> "$BACKUP_DIR/upgrade.log" 2>&1
    chmod 711 "$WORK_DIR"
    runuser -u "$WEB_USER" -- "$PHP_BIN" "$WORK_DIR/helper.php" inspect "$MOODLE_PATH" > "$BACKUP_DIR/after.json"
    chmod 700 "$WORK_DIR"
    [[ "$(json_value "$BACKUP_DIR/after.json" build)" == "$(json_value "$WORK_DIR/target-metadata.json" version)" ]] || die "Installed database build does not match downloaded code"
    if [[ "$INITIAL_CLI_MAINTENANCE" == true ]]; then
        cp -p "$WORK_DIR/original-maintenance.html" "$DATA_PATH/climaintenance.html"
    fi
    if [[ "$SKIP_RESTART" == true ]]; then
        PHASE=awaiting-restart
        error "Upgrade completed; --no-restart intentionally leaves maintenance and cron paused."
        error "Restart web/PHP workers, verify the site, then disable CLI maintenance and restore saved crontabs."
        error "Backup: $BACKUP_DIR; recovery state: $WORK_DIR"
        # Keep the state and the old tree for a manual handoff; exit distinctly.
        exit 2
    fi
    restart_workers
    disable_maintenance_mode
    restore_cron
    SUCCESS=true
    PHASE=complete
    printf 'Upgrade and cache purge completed; workers restarted; prior maintenance/cron state restored.\n' > "$BACKUP_DIR/UPDATE_COMPLETE"
    log "Updated to $target_release. Backup retained: $BACKUP_DIR"
}

# Sourceable functions make fixture tests possible without root or a Moodle site.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
