#!/usr/bin/env python3
"""Offline regression tests. Runtime updater has no Python dependency."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH_BIN', 'bash')
PHP = os.environ.get('PHP_BIN', 'php')

class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='moodle-updater-test-')
        self.p = Path(self.temp.name)
        self.helper = self.p/'helper.php'
        r = self.shell('WORK_DIR="$FIXTURE"; write_helper')
        self.assertEqual(r.returncode, 0, r.stderr)

    def tearDown(self):
        self.temp.cleanup()

    def shell(self, text, **env):
        e = dict(os.environ, FIXTURE=str(self.p), PHP_BIN=PHP, UPDATER=str(ROOT/'updater.sh'), **env)
        return subprocess.run([BASH, '-c', 'source "$UPDATER"; '+text], text=True, capture_output=True, env=e)

    def call(self, cmd, *args):
        return subprocess.run([PHP, str(self.helper), cmd, *map(str,args)], text=True, capture_output=True)

    def write(self, name, data):
        p=self.p/name; p.parent.mkdir(parents=True,exist_ok=True)
        p.write_text(json.dumps(data) if isinstance(data,(dict,list)) else data)
        return p

    def resolve(self, requested, allow=False, tags=None):
        tags = tags if tags is not None else ['v5.3.0','v5.3.0-rc2','v5.2.4','v5.2.3','v5.1.8']
        a=self.write('tags.json',[{'name':t} for t in tags])
        b=self.write('branches.json',[{'name':'main'},{'name':'MOODLE_503_STABLE'}])
        return self.call('resolve',a,b,requested,str(allow).lower())

    def test_latest_and_minor_are_stable_tags(self):
        for request,want in [('latest','refs/tags/v5.3.0'),('5.2','refs/tags/v5.2.4'),('5.2.3','refs/tags/v5.2.3')]:
            with self.subTest(request=request):
                r=self.resolve(request);self.assertEqual(r.returncode,0,r.stderr)
                self.assertEqual(json.loads(r.stdout)['ref'],want)
                self.assertFalse(json.loads(r.stdout)['unstable'])

    def test_missing_patch_does_not_fall_back(self):
        for allow in [False,True]:
            r=self.resolve('5.2.999',allow);self.assertNotEqual(r.returncode,0)
            self.assertIn('Missing patch versions',r.stderr)

    def test_prereleases_and_branches_require_opt_in(self):
        for request in ['5.3.0-rc2','main','MOODLE_503_STABLE']:
            self.assertNotEqual(self.resolve(request).returncode,0)
            r=self.resolve(request,True);self.assertEqual(r.returncode,0,r.stderr)
            self.assertTrue(json.loads(r.stdout)['unstable'])

    def test_unreleased_numeric_minor_is_not_assumed_stable(self):
        self.assertNotEqual(self.resolve('5.3',False,['v5.2.4']).returncode,0)
        r=self.resolve('main',True,['v5.2.4'])
        self.assertEqual(json.loads(r.stdout)['ref'],'refs/heads/main')

    def webroot(self,text,kind='apache'):
        return self.call('rewrite-test',self.write('web.conf',text),'/var/www/moodle','/var/www/moodle/public',kind)

    def test_apache_webroot_exact_paths_and_idempotence(self):
        original='DocumentRoot /var/www/moodle\n<Directory "/var/www/moodle/">\nDocumentRoot /var/www/moodle/public\nDocumentRoot /var/www/moodle2\n# DocumentRoot /var/www/moodle\n'
        r=self.webroot(original);self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('DocumentRoot "/var/www/moodle/public"',r.stdout)
        self.assertIn('<Directory "/var/www/moodle/public">',r.stdout)
        self.assertIn('DocumentRoot /var/www/moodle2',r.stdout)
        self.assertNotIn('/public/public',r.stdout)
        self.assertEqual(self.webroot(r.stdout).stdout,r.stdout)

    def test_webroot_without_trailing_newline(self):
        self.assertEqual(self.webroot('DocumentRoot /var/www/moodle').stdout,'DocumentRoot "/var/www/moodle/public"')

    def test_nginx_quoted_paths_and_boundary(self):
        r=self.webroot(' root "/var/www/moodle";\n root /var/www/moodle/public;\n root /var/www/moodle2;\n','nginx')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertIn('root "/var/www/moodle/public";',r.stdout)
        self.assertNotIn('/public/public',r.stdout)
        self.assertIn('root /var/www/moodle2;',r.stdout)
        self.assertEqual(self.webroot(r.stdout,'nginx').stdout,r.stdout)

    def target(self,build=2026042004,branch='502',release='5.2.4',dbmin='10.11.0',phpmin='8.1'):
        root=self.p/'target'
        self.write('target/public/version.php',f"<?php defined('MOODLE_INTERNAL')||die(); $version={build};$branch='{branch}';$release='{release}';$maturity=200;")
        self.write('target/public/admin/environment.xml',f'<COMPATIBILITY_MATRIX><MOODLE version="{release[:3]}" requires="4.4"><PHP version="{phpmin}"/><DATABASE><VENDOR name="mariadb" version="{dbmin}"/></DATABASE><PHP_EXTENSIONS><PHP_EXTENSION name="json" level="required"/></PHP_EXTENSIONS></MOODLE></COMPATIBILITY_MATRIX>')
        return root

    def current(self,**kw):
        v={'release':'5.0.1 (Build: 20250609)','build':2025041401,'dbvendor':'mariadb','dbversion':'10.11.14','dirroot':str(self.p/'old'),'plugins':[]}
        v.update(kw);return self.write('current.json',v)

    def test_requirements_use_target_xml_and_block_mariadb_10_for_53(self):
        r=self.call('requirements',self.current(),self.target(),False)
        self.assertEqual(r.returncode,0,r.stderr)
        r=self.call('requirements',self.current(),self.target(2026100500,'503','5.3.0','11.4.0'),False)
        self.assertNotEqual(r.returncode,0);self.assertIn('11.4.0',r.stderr)

    def test_downgrade_and_intermediate_upgrade_are_blocked(self):
        r=self.call('requirements',self.current(build=2026100500),self.target(),False)
        self.assertNotEqual(r.returncode,0);self.assertIn('downgrade',r.stderr)
        r=self.call('requirements',self.current(release='4.3.9'),self.target(),False)
        self.assertNotEqual(r.returncode,0);self.assertIn('intermediate',r.stderr)

    def test_php_requirement_failure_precedes_installation(self):
        r=self.call('requirements',self.current(),self.target(phpmin='99.0'),False)
        self.assertNotEqual(r.returncode,0);self.assertIn('PHP 99.0',r.stderr)

    def plugin(self,rel='local/custom',body=None):
        body=body or "<?php $plugin->component='local_custom';$plugin->version=2026010100;$plugin->requires=2025041400;$plugin->supported=[500,502];"
        self.write('old/'+rel+'/version.php',body)
        self.write('old/'+rel+'/custom.txt','keep me')
        self.write('old/'+rel+'/.git/config','private source metadata')
        return {'component':'local_custom','relative':rel,'status':'uptodate'}

    def test_plugins_and_explicit_extra_paths_survive_public_transition(self):
        current=self.current(plugins=[self.plugin()]);root=self.target()
        self.write('old/custom-brand.txt','brand')
        r=self.call('preserve',current,root,'custom-brand.txt')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((root/'public/local/custom/custom.txt').read_text(),'keep me')
        self.assertFalse((root/'public/local/custom/.git').exists())
        self.assertEqual((root/'public/custom-brand.txt').read_text(),'brand')

    def test_incompatible_plugin_and_core_collision_are_blocked(self):
        p=self.plugin(body="<?php $plugin->requires=2099010100;")
        r=self.call('preserve',self.current(plugins=[p]),self.target())
        self.assertNotEqual(r.returncode,0);self.assertIn('newer Moodle',r.stderr)
        p=self.plugin();self.write('target/public/local/custom/version.php','<?php')
        r=self.call('preserve',self.current(plugins=[p]),self.target())
        self.assertNotEqual(r.returncode,0);self.assertIn('overwrite target core',r.stderr)

    def test_missing_plugin_is_reported_without_uninstalling(self):
        p={'component':'mod_scheduler','relative':None,'status':'missing'}
        r=self.call('preserve',self.current(plugins=[p]),self.target())
        self.assertEqual(r.returncode,0,r.stderr);self.assertIn('Already missing',r.stderr)
        self.assertFalse((self.p/'target/public/mod/scheduler').exists())

    def test_preserved_symlink_and_path_traversal_are_blocked(self):
        root=self.target();current=self.current()
        self.write('outside','secret');(self.p/'old').mkdir(exist_ok=True)
        (self.p/'old/link').symlink_to(self.p/'outside')
        for rel in ['../outside','/absolute','link']:
            self.assertNotEqual(self.call('preserve',current,root,rel).returncode,0)

    def test_nested_plugins_are_copied_once(self):
        p=self.plugin('mod/custom');q=self.plugin('mod/custom/subplugin/extra')
        r=self.call('preserve',self.current(plugins=[q,p]),self.target())
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(r.stdout.count('Preserved '),1)
        self.assertTrue((self.p/'target/public/mod/custom/subplugin/extra/version.php').exists())

    def test_bootstrap_migrates_before_require_and_rejects_unknown_loader(self):
        f=self.write('config.php',"<?php\n$CFG = new stdClass();\nrequire_once(__DIR__ . '/lib/setup.php'); // Do not edit\n")
        r=self.call('bootstrap',f,'true');self.assertEqual(r.returncode,0,r.stderr)
        s=f.read_text();self.assertIn("$CFG->dirroot = __DIR__ . '/public';",s)
        self.assertLess(s.index('$CFG->libdir ='),s.index('require_once'))
        f.write_text("<?php load_my_config();")
        self.assertNotEqual(self.call('bootstrap',f,'true').returncode,0)

    def test_archive_paths_and_links_are_checked_before_extraction(self):
        for content,ok in [('moodle/\nmoodle/public/index.php\n',True),('moodle/../../escape\n',False),('/absolute\n',False),('one/\ntwo/\n',False)]:
            r=self.call('archive-list',self.write('list',content));self.assertEqual(r.returncode==0,ok,r.stderr)
        for mode,ok in [('-rw-r--r-- x',True),('drwxr-xr-x x',True),('lrwxrwxrwx x -> outside',False),('hrw-r--r-- x',False)]:
            r=self.call('archive-types',self.write('types',mode));self.assertEqual(r.returncode==0,ok,r.stderr)

    def test_credentials_are_private_and_not_printed(self):
        secret='a"quote\\backslash\nline'
        config="<?php if(!defined('CLI_SCRIPT'))throw new Exception('guard missing'); $CFG=(object)json_decode("+json.dumps(json.dumps({'dbhost':'localhost','dbname':'moodle','dbuser':'moodle','dbpass':secret,'dboptions':{'dbport':3307}})) + ",true);"
        self.write('site/config.php',config)
        auth=self.p/'auth'
        r=self.call('db-auth',self.p/'site',auth,'mariadb')
        self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn(secret,r.stdout+r.stderr)
        self.assertEqual(auth.stat().st_mode&0o777,0o600)
        self.assertIn('port="3307"',auth.read_text());self.assertIn('\\nline',auth.read_text())

    def test_failed_database_dump_cannot_continue_to_install(self):
        self.write('current.json',{'dbvendor':'mariadb'})
        r=self.shell(r'''WORK_DIR="$FIXTURE"; BACKUP_DIR="$FIXTURE"; MOODLE_PATH="$FIXTURE/site";
php_helper(){ if [[ "$1" == db-auth ]]; then touch "$2/auth" 2>/dev/null || touch "$FIXTURE/db-auth"; printf '{"name":"moodle"}'; fi; }
mysqldump(){ printf partial; return 7; }
backup_database
printf installed > "$FIXTURE/installed"
''')
        self.assertNotEqual(r.returncode,0);self.assertFalse((self.p/'installed').exists())

    def test_insufficient_space_stops_preflight(self):
        r=self.shell(r'''WORK_DIR="$FIXTURE"; DATA_PATH=/data; MOODLE_PATH=/code; BACKUP_ROOT=/backup;
du(){ printf '1000000 path\n'; }; df(){ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 100 99 1 99%% /\n'; }; json_value(){ printf 1000000; }
check_disk_space
printf installed > "$FIXTURE/installed"
''')
        self.assertNotEqual(r.returncode,0);self.assertIn('Insufficient backup space',r.stderr)
        self.assertFalse((self.p/'installed').exists())

    def test_cron_restore_preserves_concurrent_edits(self):
        self.write('cron-root.before','* * * * * php /moodle/admin/cli/cron.php\n')
        self.write('cron-live','# moodle-updater paused: * * * * * php /moodle/admin/cli/cron.php\n0 4 * * * new-job\n')
        r=self.shell(r'''WORK_DIR="$FIXTURE"; CRON_SAVED=(root);
crontab(){ if [[ "${3:-}" == -l ]]; then cat "$FIXTURE/cron-live"; else cp "$3" "$FIXTURE/cron-result"; fi; }
restore_cron
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual((self.p/'cron-result').read_text(),'* * * * * php /moodle/admin/cli/cron.php\n0 4 * * * new-job\n')

    def test_failure_before_migration_restores_original_code(self):
        self.write('stage/old/version','old');self.write('site/version','new');self.write('data/climaintenance.html','blocked')
        r=self.shell(r'''WORK_DIR="$FIXTURE/work"; mkdir "$WORK_DIR"; STAGE_DIR="$FIXTURE/stage"; MOODLE_PATH="$FIXTURE/site"; DATA_PATH="$FIXTURE/data"; OLD_CODE="$STAGE_DIR/old";
CODE_SWAPPED=true; OLD_MOVED=true; MAINTENANCE_CHANGED=true; PHASE=installing;
restore_web_configs(){ :; }; restart_workers(){ :; }; restore_cron(){ :; }; disable_maintenance_mode(){ php -r 'unlink($argv[1]);' "$DATA_PATH/climaintenance.html"; }
trap cleanup EXIT
exit 9
''')
        self.assertEqual(r.returncode,9,r.stderr)
        self.assertEqual((self.p/'site/version').read_text(),'old')
        self.assertFalse((self.p/'data/climaintenance.html').exists())

    def test_failure_after_migration_keeps_new_code_and_maintenance(self):
        self.write('stage/old/version','old');self.write('site/version','new');(self.p/'data').mkdir()
        r=self.shell(r'''WORK_DIR="$FIXTURE/work"; mkdir "$WORK_DIR"; STAGE_DIR="$FIXTURE/stage"; MOODLE_PATH="$FIXTURE/site"; DATA_PATH="$FIXTURE/data"; OLD_CODE="$STAGE_DIR/old";
CODE_SWAPPED=true; OLD_MOVED=true; PHASE=migrating; CRON_SAVED=(root); crontab(){ :; }
trap cleanup EXIT
exit 9
''')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual((self.p/'site/version').read_text(),'new')
        self.assertTrue((self.p/'data/climaintenance.html').exists())
        self.assertTrue((self.p/'work').exists())

    def test_no_restart_handoff_keeps_maintenance_and_distinct_exit(self):
        self.write('site/version','new');(self.p/'data').mkdir()
        r=self.shell(r'''WORK_DIR="$FIXTURE/work"; mkdir "$WORK_DIR"; STAGE_DIR="$FIXTURE/stage"; MOODLE_PATH="$FIXTURE/site"; DATA_PATH="$FIXTURE/data";
PHASE=awaiting-restart; CRON_SAVED=(root); crontab(){ :; }
trap cleanup EXIT
exit 2
''')
        self.assertEqual(r.returncode,2,r.stderr)
        self.assertTrue((self.p/'data/climaintenance.html').exists())
        self.assertTrue((self.p/'work').exists())

    def test_prerelease_maturity_is_checked_again_after_download(self):
        root=self.target();f=root/'public/version.php';f.write_text(f.read_text().replace('$maturity=200','$maturity=150'))
        self.assertNotEqual(self.call('requirements',self.current(),root,'false').returncode,0)
        self.assertEqual(self.call('requirements',self.current(),root,'true').returncode,0)

    def test_postgres_password_escaping_and_socket_host(self):
        cfg={'dbhost':'/var/run/postgresql','dbname':'moodle','dbuser':'moodle','dbpass':'colon:back\\slash','dboptions':{}}
        self.write('site/config.php',"<?php $CFG=(object)json_decode("+json.dumps(json.dumps(cfg))+",true);")
        auth=self.p/'pgpass';r=self.call('db-auth',self.p/'site',auth,'postgres')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(auth.read_text().startswith('localhost:5432:moodle:moodle:'))
        self.assertIn(r'colon\:back\\slash',auth.read_text())
        self.assertNotIn(cfg['dbpass'],r.stdout+r.stderr)

    def test_restart_only_selected_fpm_services(self):
        r=self.shell(r'''WORK_DIR="$FIXTURE"; WEB_SERVICE=apache2; FPM_SERVICES=(php8.3-fpm.service); web_configtest(){ :; }; systemctl(){ printf '%s\n' "$*" >> "$FIXTURE/service-calls"; }
restart_workers
''')
        self.assertEqual(r.returncode,0,r.stderr)
        calls=(self.p/'service-calls').read_text()
        self.assertIn('restart php8.3-fpm.service',calls)
        self.assertIn('restart apache2',calls)
        self.assertNotIn('list-units',calls)
        self.assertNotIn('php8.2',calls)

    def test_staging_space_is_checked_before_download(self):
        r=self.shell(r'''WORK_DIR="$FIXTURE"; MOODLE_PATH=/code; du(){ printf '1000000 path\n'; }; df(){ printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 100 99 1 99%% /\n'; }
check_staging_space
printf downloaded > "$FIXTURE/downloaded"
''')
        self.assertNotEqual(r.returncode,0)
        self.assertIn('Insufficient space',r.stderr)
        self.assertFalse((self.p/'downloaded').exists())

    def test_exact_older_tag_can_be_resolved_outside_first_page(self):
        r=self.shell(r'''WORK_DIR="$FIXTURE";
fetch_json(){ if [[ "$1" == *git/ref/tags/v4.5.1 ]]; then printf '{"ref":"refs/tags/v4.5.1"}' > "$2"; else printf '[{"name":"v5.3.0"}]' > "$2"; fi; }
resolve_moodle_target 4.5.1
cat "$WORK_DIR/target.json"
''')
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(r.stdout)['ref'],'refs/tags/v4.5.1')

if __name__=='__main__':unittest.main(verbosity=2)
