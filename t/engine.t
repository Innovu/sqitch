#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
#use Test::More tests => 122;
use Test::More 'no_plan';
use App::Sqitch;
use App::Sqitch::Plan;
use Path::Class;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use lib 't/lib';
use MockOutput;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine';
    use_ok $CLASS or die;
    delete $ENV{PGDATABASE};
    delete $ENV{PGUSER};
    delete $ENV{USER};
    $ENV{SQITCH_CONFIG} = 'nonexistent.conf';
}

can_ok $CLASS, qw(load new name);

my ($is_deployed_tag, $is_deployed_step) = (0, 0);
my @deployed_steps;
my @missing_requires;
my @conflicts;
my $die = '';
my ($latest_item, $latest_tag, $latest_step, $initialized);
ENGINE: {
    # Stub out a engine.
    package App::Sqitch::Engine::whu;
    use Moose;
    use App::Sqitch::X qw(hurl);
    extends 'App::Sqitch::Engine';
    $INC{'App/Sqitch/Engine/whu.pm'} = __FILE__;

    my @SEEN;
    for my $meth (qw(
        run_file
        log_deploy_step
        log_revert_step
        log_fail_step
        log_apply_tag
        log_remove_tag
    )) {
        no strict 'refs';
        *$meth = sub {
            hurl 'AAAH!' if $die eq $meth;
            push @SEEN => [ $meth => $_[1] ];
        };
    }
    sub is_deployed_tag   { push @SEEN => [ is_deployed_tag   => $_[1] ]; $is_deployed_tag }
    sub is_deployed_step  { push @SEEN => [ is_deployed_step  => $_[1] ]; $is_deployed_step }
    sub check_requires    { push @SEEN => [ check_requires    => $_[1] ]; @missing_requires }
    sub check_conflicts   { push @SEEN => [ check_conflicts   => $_[1] ]; @conflicts }
    sub latest_item       { push @SEEN => [ latest_item       => $_[1] ]; $latest_item }
    sub latest_tag        { push @SEEN => [ latest_tag        => $_[1] ]; $latest_tag }
    sub latest_step       { push @SEEN => [ latest_step       => $_[1] ]; $latest_step }
    sub initialized       { push @SEEN => 'initialized'; $initialized }
    sub initialize        { push @SEEN => 'initialize' }

    sub seen { [@SEEN] }
    after seen => sub { @SEEN = () };
}

ok my $sqitch = App::Sqitch->new(db_name => 'mydb'),
    'Load a sqitch sqitch object';

##############################################################################
# Test new().
throws_ok { $CLASS->new }
    qr/\QAttribute (sqitch) is required/,
    'Should get an exception for missing sqitch param';
my $array = [];
throws_ok { $CLASS->new({ sqitch => $array }) }
    qr/\QValidation failed for 'App::Sqitch' with value/,
    'Should get an exception for array sqitch param';
throws_ok { $CLASS->new({ sqitch => 'foo' }) }
    qr/\QValidation failed for 'App::Sqitch' with value/,
    'Should get an exception for string sqitch param';

isa_ok $CLASS->new({sqitch => $sqitch}), $CLASS;

##############################################################################
# Test load().
ok my $engine = $CLASS->load({
    sqitch => $sqitch,
    engine => 'whu',
}), 'Load a "whu" engine';
isa_ok $engine, 'App::Sqitch::Engine::whu';
is $engine->sqitch, $sqitch, 'The sqitch attribute should be set';

# Test handling of an invalid engine.
throws_ok { $CLASS->load({ engine => 'nonexistent', sqitch => $sqitch }) }
    'App::Sqitch::X', 'Should die on invalid engine';
is $@->message, 'Unable to load App::Sqitch::Engine::nonexistent',
    'Should get load error message';
like $@->previous_exception, qr/\QCan't locate/,
    'Should have relevant previoius exception';

NOENGINE: {
    # Test handling of no engine.
    throws_ok { $CLASS->load({ engine => '', sqitch => $sqitch }) }
        'App::Sqitch::X',
            'No engine should die';
    is $@->message, 'Missing "engine" parameter to load()',
        'It should be the expected message';
}

# Test handling a bad engine implementation.
use lib 't/lib';
throws_ok { $CLASS->load({ engine => 'bad', sqitch => $sqitch }) }
    'App::Sqitch::X', 'Should die on bad engine module';
is $@->message, 'Unable to load App::Sqitch::Engine::bad',
    'Should get another load error message';
like $@->previous_exception, qr/^LOL BADZ/,
    'Should have relevant previoius exception from the bad module';

##############################################################################
# Test name.
can_ok $CLASS, 'name';
ok $engine = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
is $CLASS->name, '', 'Base class name should be ""';
is $engine->name, '', 'Base object name should be ""';

ok $engine = App::Sqitch::Engine::whu->new({sqitch => $sqitch}),
    'Create a subclass name object';
is $engine->name, 'whu', 'Subclass oject name should be "whu"';
is +App::Sqitch::Engine::whu->name, 'whu', 'Subclass class name should be "whu"';

##############################################################################
# Test config_vars.
can_ok 'App::Sqitch::Engine', 'config_vars';
is_deeply [App::Sqitch::Engine->config_vars], [],
    'Should have no config vars in engine base class';

##############################################################################
# Test abstract methods.
ok $engine = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object again";
for my $abs (qw(
    initialized
    initialize
    run_file
    run_handle
    log_deploy_step
    log_fail_step
    log_revert_step
    log_apply_tag
    log_remove_tag
    is_deployed_tag
    is_deployed_step
    check_requires
    check_conflicts
    latest_item
    latest_tag
    latest_step
)) {
    throws_ok { $engine->$abs } qr/\Q$CLASS has not implemented $abs()/,
        "Should get an unimplemented exception from $abs()"
}

##############################################################################
# Test deploy_step and revert_step.
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Create a subclass name object again';
can_ok $engine, 'deploy_step', 'revert_step';

my $step = App::Sqitch::Plan::Step->new( name => 'foo', plan => $sqitch->plan );

ok $engine->deploy_step($step), 'Deploy a step';
is_deeply $engine->seen, [
    [check_conflicts => $step ],
    [check_requires => $step ],
    [run_file => $step->deploy_file ],
    [log_deploy_step => $step ],
], 'deploy_step should have called the proper methods';
is_deeply +MockOutput->get_info, [[
    '  + ', 'foo'
]], 'Output should reflect the deployment';

# Make it fail.
$die = 'run_file';
throws_ok { $engine->deploy_step($step) } 'App::Sqitch::X',
    'Deploy step with error';
is $@->message, 'AAAH!', 'Error should be from run_file';
is_deeply $engine->seen, [
    [check_conflicts => $step ],
    [check_requires => $step ],
    [log_fail_step => $step ],
], 'Should have logged step failure';
$die = '';
is_deeply +MockOutput->get_info, [[
    '  + ', 'foo'
]], 'Output should reflect the deployment, even with failure';

ok $engine->revert_step($step), 'Revert a step';
is_deeply $engine->seen, [
    [run_file => $step->revert_file ],
    [log_revert_step => $step ],
], 'revert_step should have called the proper methods';
is_deeply +MockOutput->get_info, [[
    '  - ', 'foo'
]], 'Output should reflect reversion';


##############################################################################
# Test apply_tag and remove_tag.
can_ok $engine, 'apply_tag', 'remove_tag';

my $tag  = App::Sqitch::Plan::Tag->new( name => 'foo', plan => $sqitch->plan );
ok $engine->apply_tag($tag), 'Applay a tag';
is_deeply $engine->seen, [
    [log_apply_tag => $tag ],
], 'Tag should have been applied';
is_deeply +MockOutput->get_info, [[
    '+ ', '@foo'
]], 'Output should show tag application';

ok $engine->remove_tag($tag), 'Remove a tag';
is_deeply $engine->seen, [
    [log_remove_tag => $tag ],
], 'Tag should have been removed';
is_deeply +MockOutput->get_info, [[
    '- ', '@foo'
]], 'Output should show tag removal';

##############################################################################
# Test _sync_plan()
can_ok $CLASS, '_sync_plan';
chdir 't';

my $plan_file = file qw(sql sqitch.plan);
$sqitch = App::Sqitch->new( plan_file => $plan_file );
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Engine with sqitch with plan file';
my $plan = $sqitch->plan;
is $plan->position, -1, 'Plan should start at position -1';
ok $engine->_sync_plan, 'Sync the plan';
is $plan->position, -1, 'Plan should still be at position -1';
$plan->position(4);
ok $engine->_sync_plan, 'Sync the plan again';
is $plan->position, -1, 'Plan should again be at position -1';

# Have latest_item return a tag.
$latest_item = '@alpha';
ok $engine->_sync_plan, 'Sync the plan to a tag';
is $plan->position, 2, 'Plan should now be at position 2';

# Have it return a step before any tag.
$latest_item = 'users';
ok $engine->_sync_plan, 'Sync the plan to a step with no tags';
is $plan->position, 1, 'Plan should now be at position 1';

# Have it return a duplicated step.
$plan->add_step('users');
$plan->reset;
ok $engine->_sync_plan, 'Sync the plan to a dupe step with no tags';
is $plan->position, 1, 'Plan should again be at position 1';

# Have it return a step after a tag.
$latest_tag = '@beta';
ok $engine->_sync_plan, 'Sync the plan to a dupe step afer a tag';
is $plan->position, 5, 'Plan should now be at position 5';

# Try it after an earlier tag.
$latest_tag = '@alpha';
ok $engine->_sync_plan, 'Sync the plan to a dupe step afer @alpha';
is $plan->position, 5, 'Plan should still be at position 5';

# Try to find a non-existent tag'.
$latest_item = '@nonexistent';
throws_ok { $engine->_sync_plan } 'App::Sqitch::X',
    'Should get error for nonexistent tag';
is $@->ident, 'plan', 'Should be a "plan" exception';
is $@->message, __x(
    'Cannot find {target} in the plan',
    target => $latest_item,
), 'It should inform the user of the error';

# Try to find a non-existent step.
$latest_item = 'nonexistent';
throws_ok { $engine->_sync_plan } 'App::Sqitch::X',
    'Should get error for nonexistent step ';
is $@->ident, 'plan', 'Should be another "plan" exception';
is $@->message, __x(
    'Cannot find {target} after {tag} in the plan',
    target => $latest_item,
    tag    => $latest_tag,
), 'It should inform the user of the nonexistent step';

# Try to find an existing step not found after the current tag.
$latest_item = 'roles';
throws_ok { $engine->_sync_plan } 'App::Sqitch::X',
    'Should get error for misplaced step ';
is $@->ident, 'plan', 'Should be yet another "plan" exception';
is $@->message, __x(
    'Cannot find {target} after {tag} in the plan',
    target => $latest_item,
    tag    => $latest_tag,
), 'It should inform the user of the misplaced step';

##############################################################################
# Test deploy.
can_ok $CLASS, 'deploy';
$latest_item = $latest_tag = undef;
$plan->reset;
$engine->seen;
my @nodes = $plan->nodes;

# Mock the deploy methods to log which were called.
my $mock_engine = Test::MockModule->new($CLASS);
my $deploy_meth;
for my $meth (qw(_deploy_all _deploy_by_tag _deploy_by_step)) {
    my $orig = $CLASS->can($meth);
    $mock_engine->mock($meth => sub {
        $deploy_meth = $meth;
        $orig->(@_);
    });
}

ok $engine->deploy('@alpha'), 'Deploy to @alpha';
is $plan->position, 2, 'Plan should be at position 2';
is_deeply $engine->seen, [
    [latest_item => undef],
    'initialized',
    'initialize',
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
    [log_apply_tag => $nodes[2]],
], 'Should have deployed through @alpha';

is $deploy_meth, '_deploy_all', 'Should have called _deploy_all()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination} through {target}',
        destination =>  $engine->destination,
        target      => '@alpha'
    ],
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
], 'Should have seen the output of the deploy to @alpha';

# Try with no need to initialize.
$initialized = 1;
$plan->reset;
ok $engine->deploy('@alpha', 'tag'), 'Deploy to @alpha with tag mode';
is $plan->position, 2, 'Plan should again be at position 2';
is_deeply $engine->seen, [
    [latest_item => undef],
    'initialized',
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
    [log_apply_tag => $nodes[2]],
], 'Should have deployed through @alpha without initialization';

is $deploy_meth, '_deploy_by_tag', 'Should have called _deploy_by_tag()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination} through {target}',
        destination =>  $engine->destination,
        target      => '@alpha'
    ],
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
], 'Should have seen the output of the deploy to @alpha';

# Try a bogus target.
throws_ok { $engine->deploy('nonexistent') } 'App::Sqitch::X',
    'Should get an error for an unknown target';
is $@->message, __x(
    'Unknown deploy target: "{target}"',
    target => 'nonexistent',
), 'The exception should report the unknown target';
is_deeply $engine->seen, [
    [latest_item => undef],
], 'Only latest_item() should have been called';

# Start with @alpha.
$latest_item = '@alpha';
ok $engine->deploy('@alpha'), 'Deploy to alpha thrice';
is_deeply $engine->seen, [
    [latest_item => undef],
], 'Only latest_item() should have been called';
is_deeply +MockOutput->get_info, [
    [__x 'Nothing to deploy (already at "{target}"', target => '@alpha'],
], 'Should notify user that already at @alpha';

# Start with widgets.
$latest_item = 'widgets';
throws_ok { $engine->deploy('@alpha') } 'App::Sqitch::X',
    'Should fail targeting older node';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message,  __ 'Cannot deploy to an earlier target; use "revert" instead',
    'It should suggest using "revert"';
is_deeply $engine->seen, [
    [latest_item => undef],
    [latest_tag => undef],
], 'Should have called latest_item() and latest_tag()';

# Deploy to latest.
$latest_item = 'users';
$latest_tag = '@beta';
ok $engine->deploy, 'Deploy to latest target';
is_deeply $engine->seen, [
    [latest_item => undef],
    [latest_tag => undef],
], 'Again, only latest_item() and latest_tag() should have been called';
is_deeply +MockOutput->get_info, [
    [__ 'Nothing to deploy (up-to-date)'],
], 'Should notify user that already up-to-date';

# Make sure we can deploy everything by step.
$latest_item = $latest_tag = undef;
ok $engine->deploy(undef, 'step'), 'Deploy everything by step';
is $plan->position, 5, 'Plan should be at position 5';
is_deeply $engine->seen, [
    [latest_item => undef],
    'initialized',
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
    [log_apply_tag => $nodes[2]],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [run_file => $nodes[3]->deploy_file],
    [log_deploy_step => $nodes[3]],
    [log_apply_tag => $nodes[4]],
    [check_conflicts => $nodes[5] ],
    [check_requires => $nodes[5] ],
    [run_file => $nodes[5]->deploy_file],
    [log_deploy_step => $nodes[5]],
], 'Should have deployed everything';

is $deploy_meth, '_deploy_by_step', 'Should have called _deploy_by_step()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination}', destination =>  $engine->destination ],
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
    ['  + ', 'widgets'],
    ['+ ', '@beta'],
    ['  + ', 'users'],
], 'Should have seen the output of the deploy to the end';

# Try invalid mode.
throws_ok { $engine->deploy(undef, 'evil_mode') } 'App::Sqitch::X',
    'Should fail on invalid mode';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message, __x('Unknown deployment mode: "{mode}"', mode => 'evil_mode'),
    'And the message should reflect the unknown mode';
is_deeply $engine->seen, [
    [latest_item => undef],
    'initialized',
], 'It should have check for initialization';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination}', destination =>  $engine->destination ],
], 'Should have announced destination';

# Try a plan with no steps.
NOSTEPS: {
    my $plan_file = file qw(nonexistent.plan);
    my $sqitch = App::Sqitch->new( plan_file => $plan_file );
    ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
        'Engine with sqitch with no file';
    throws_ok { $engine->deploy } 'App::Sqitch::X', 'Should die with no steps';
    is $@->message, __"Nothing to deploy (empty plan)",
        'Should have the localized message';
    is_deeply $engine->seen, [
        [latest_item => undef],
    ], 'It should have checked for the latest item';
}

##############################################################################
# Test _deploy_by_step()
$plan->reset;
$mock_engine->unmock('_deploy_by_step');
ok $engine->_deploy_by_step($plan, 2), 'Deploy stepwise to index 2';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
    [log_apply_tag => $nodes[2]],
], 'Should stepwise deploy to index 2';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
], 'Should have seen output of each node';

ok $engine->_deploy_by_step($plan, 4), 'Deploy stepwise to index 4';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [run_file => $nodes[3]->deploy_file],
    [log_deploy_step => $nodes[3]],
    [log_apply_tag => $nodes[4]],
], 'Should stepwise deploy to from index 2 to index 4';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets'],
    ['+ ', '@beta'],
], 'Should have seen output of nodes 3-4';

# Make it die.
$plan->reset;
$die = 'run_file';
throws_ok { $engine->_deploy_by_step($plan, 2) } 'App::Sqitch::X',
    'Die in _deploy_by_step';
is $@->message, 'AAAH!', 'It should have died in run_file';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [log_fail_step => $nodes[0] ],
], 'It should have logged the failure';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
], 'Should have seen output for first node';
$die = '';

##############################################################################
# Test _deploy_by_tag().
$plan->reset;
$mock_engine->unmock('_deploy_by_tag');
ok $engine->_deploy_by_tag($plan, 2), 'Deploy tagwise to index 2';

is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
    [log_apply_tag => $nodes[2]],
], 'Should tagwise deploy to index 2';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
], 'Should have seen output of each node';

ok $engine->_deploy_by_tag($plan, 4), 'Deploy tagwise to index 4';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [run_file => $nodes[3]->deploy_file],
    [log_deploy_step => $nodes[3]],
    [log_apply_tag => $nodes[4]],
], 'Should tagwise deploy to from index 2 to index 4';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets'],
    ['+ ', '@beta'],
], 'Should have seen output of nodes 3-4';

# Make it die.
$plan->reset;
$die = 'log_apply_tag';
throws_ok { $engine->_deploy_by_tag($plan, 2) } 'App::Sqitch::X',
    'Die in _deploy_by_tag';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
    [run_file => $nodes[1]->revert_file],
    [log_revert_step => $nodes[1]],
    [run_file => $nodes[0]->revert_file],
    [log_revert_step => $nodes[0]],
], 'It should have logged up to the failure';

is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
    ['  - ', 'users'],
    ['  - ', 'roles'],
], 'Should have seen deploy and revert messages';
is_deeply +MockOutput->get_vent, [
    ['AAAH!'],
    [__ 'Reverting to previous state']
], 'The original error should have been vented';
$die = '';

# Now have it fail on a later node, to keep the first tag.
$plan->reset;
my $mock_whu = Test::MockModule->new('App::Sqitch::Engine::whu');
$mock_whu->mock(run_file => sub { die 'ROFL' if $_[1]->basename eq 'widgets.sql' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag again';
is $@->message, __('Deploy failed'), 'Should again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [log_deploy_step => $nodes[1]],
    [log_apply_tag => $nodes[2]],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [log_fail_step => $nodes[3]],
], 'Should have logged deploy and no reverts';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
    ['  + ', 'widgets'],
], 'Should have seen deploy messages';
my $vented = MockOutput->get_vent;
is @{ $vented }, 1, 'Should have one vented message';
like $vented->[0][0], qr/^ROFL\b/, 'And it should be the underlying error';

# Add a step and deploy to that, to make sure it rolls back any steps since
# last tag.
$plan->add_step('dr_evil');
@nodes = $plan->nodes;
$plan->reset;
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'dr_evil.sql' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag yet again';
is $@->message, __('Deploy failed'), 'Should die "Deploy failed" again';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [log_deploy_step => $nodes[1]],
    [log_apply_tag => $nodes[2]],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [log_deploy_step => $nodes[3]],
    [log_apply_tag => $nodes[4]],
    [check_conflicts => $nodes[5] ],
    [check_requires => $nodes[5] ],
    [log_deploy_step => $nodes[5]],
    [check_conflicts => $nodes[6] ],
    [check_requires => $nodes[6] ],
    [log_fail_step => $nodes[6]],
    [log_revert_step => $nodes[5] ],
], 'Should have reverted last step';

is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
    ['  + ', 'widgets'],
    ['+ ', '@beta'],
    ['  + ', 'users'],
    ['  + ', 'dr_evil'],
    ['  - ', 'users'],
], 'Should have seen user step reversion message';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {target}', target => '@beta']
], 'Should see underlying error and reversion message';

# Make it choke on step reversion.
$mock_whu->unmock_all;
$die = 'log_revert_step';
$plan->reset;
$mock_whu->mock(log_apply_tag => sub { hurl 'ROFL' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag again';
is $@->message, __('Deploy failed'), 'Should once again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file ],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file ],
    [log_deploy_step => $nodes[1]],
    [run_file => $nodes[1]->revert_file],
], 'Should have tried to revert one step';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users'],
    ['+ ', '@alpha'],
    ['  - ', 'users'],
], 'Should have seen revert message';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to previous state'],
    ['AAAH!'],
    [__ 'The schema will need to be manually repaired']
], 'Should get reversion failure message';

$die = '';
exit;

# Try a tag with no steps.
ok $engine->deploy($tag), 'Deploy a tag with no steps';
is_deeply +MockOutput->get_info, [], 'Should get no message';
is_deeply +MockOutput->get_warn, [
    ['Tag ', $tag->name, ' has no steps; skipping']
], 'Should get warning about no steps';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
], 'Should have checked if the tag was already deployed';

# Try a tag that's already "deployed".
$is_deployed_tag = 1;
ok $engine->deploy($tag), 'Deploy a deployed tag';
is_deeply +MockOutput->get_info, [
    ['Tag ', $tag->name, ' already deployed to ', 'mydb']
], 'Should get info that the tag is already deployed';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag],
], 'Only is_deployed_tag should have been called';
$is_deployed_tag = 0;

# Add a step to this tag.
push @{ $tag->_steps } => $step;
ok $engine->deploy($tag), 'Deploy tag with a single step';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
], 'Should get info message about tag and step deployment';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
    [begin_deploy_tag => $tag],
    [is_deployed_step => $step ],
    [check_conflicts => $step],
    [check_requires => $step],
    [run_file => $step->deploy_file ],
    [log_deploy_step => $step ],
    [commit_deploy_tag => $tag],
], 'The step and tag should have been deployed and logged';

# Add a second step.
my $step2 = App::Sqitch::Plan::Step->new( name => 'bar',  tag  => $tag );
push @{ $tag->_steps } => $step2;
ok $engine->deploy($tag), 'Deploy tag with two steps';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
], 'Should get info message about tag and both step deployments';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
    [begin_deploy_tag => $tag],
    [is_deployed_step => $step ],
    [check_conflicts => $step],
    [check_requires => $step],
    [run_file => $step->deploy_file ],
    [log_deploy_step => $step ],
    [is_deployed_step => $step2 ],
    [check_conflicts => $step2],
    [check_requires => $step2],
    [run_file => $step2->deploy_file ],
    [log_deploy_step => $step2 ],
    [commit_deploy_tag => $tag],
], 'Both steps and the tag should have been deployed and logged';

# Try it with steps already deployed.
$is_deployed_step = 1;
ok $engine->deploy($tag), 'Deploy tag with two steps';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['    ', $step->name, ' already deployed' ],
    ['    ', $step2->name, ' already deployed' ],
], 'Should get info message about steps already deployed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
    [begin_deploy_tag => $tag],
    [is_deployed_step => $step ],
    [is_deployed_step => $step2 ],
    [commit_deploy_tag => $tag ],
], 'Steps should not be re-deployed';
$is_deployed_step = 0;

# Die on the first step.
my $crash_in = 1;
my $mock = Test::MockModule->new(ref $engine, no_auto => 1);
$mock->mock(deploy_step => sub { die 'OMGWTFLOL' if --$crash_in == 0; });

throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
], 'Should get info message about tag and first step';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
my $debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message';
like $debug->[0][0], qr/^OMGWTFLOL\b/, 'And it should be the original error';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
    [begin_deploy_tag => $tag],
    [is_deployed_step => $step ],
    [check_conflicts => $step],
    [check_requires => $step],
    [log_fail_step => $step ],
    [rollback_deploy_tag => $tag ],
], 'The tag should be rolled back';

# Try bailing on the second step.
$crash_in = 2;
throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die again';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
    ['  - ', $step->name ],
], 'Should get info message including reversion of first step';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
$debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message again';
like $debug->[0][0], qr/^OMGWTFLOL\b/, 'And it should again be the original error';
is_deeply +MockOutput->get_vent, [
    ['Reverting previous steps for tag ', $tag->name]
], 'The reversion should have been vented';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
    [begin_deploy_tag => $tag],
    [is_deployed_step => $step ],
    [check_conflicts => $step],
    [check_requires => $step],
    [is_deployed_step => $step2 ],
    [check_conflicts => $step2],
    [check_requires => $step2],
    [log_fail_step => $step2 ],
    [run_file => $step->revert_file ],
    [log_revert_step => $step ],
    [rollback_deploy_tag => $tag ],
], 'The first step and the tag should be reverted and rolled back';

# Now choke on a reversion, too (add insult to injury).
$crash_in = 2;
$mock->mock(revert_step => sub { die 'OWOWOW' });
throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die thrice';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
    ['  - ', $step->name ],
], 'Should get info message including reversion of first step';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
$debug = MockOutput->get_debug;
is @{ $debug }, 2, 'Should have two debug messages';
like $debug->[0][0], qr/^OMGWTFLOL\b/, 'The first should be the original error';
like $debug->[1][0], qr/^OWOWOW\b/, 'The second should be the revert error';
is_deeply +MockOutput->get_vent, [
    [ 'Reverting previous steps for tag ', $tag->name],
    [ 'Error rolling back ', $tag->name, $/,
      'The schema will need to be manually repaired'
    ],
], 'The reversion and its failure should have been vented';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
    [begin_deploy_tag => $tag],
    [is_deployed_step => $step ],
    [check_conflicts => $step],
    [check_requires => $step],
    [is_deployed_step => $step2 ],
    [check_conflicts => $step2],
    [check_requires => $step2],
    [log_fail_step => $step2 ],
], 'The revert and rollback should not appear';

# Now get all the way through, but choke when tagging.
$mock->unmock_all;
$mock->mock(commit_deploy_tag => sub { die 'WHYME!' });
throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die on bad tag';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
    ['  - ', $step2->name ],
    ['  - ', $step->name ],
], 'Should get info message including reversion of both steps';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
$debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message';
like $debug->[0][0], qr/^WHYME!/, 'And it should be the original error';
is_deeply +MockOutput->get_vent, [
    [ 'Reverting previous steps for tag ', $tag->name],
], 'The reversion should have been vented';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag ],
    [begin_deploy_tag => $tag],
    [is_deployed_step => $step ],
    [check_conflicts => $step],
    [check_requires => $step],
    [run_file => $step->deploy_file],
    [log_deploy_step => $step],
    [is_deployed_step => $step2 ],
    [check_conflicts => $step2],
    [check_requires => $step2],
    [run_file => $step2->deploy_file ],
    [log_deploy_step => $step2],
    [run_file => $step2->revert_file],
    [log_revert_step => $step2 ],
    [run_file => $step->revert_file],
    [log_revert_step => $step ],
    [rollback_deploy_tag => $tag ],
], 'Both steps should be reverted and the tag rolled back';

##############################################################################
# Test revert.
can_ok $CLASS, 'revert';
$engine->seen;
$is_deployed_tag = 1;
$is_deployed_step = 1;

# Try a tag with no steps.
@{ $tag->_steps } = ();
ok $engine->revert($tag), 'Revert a tag with no steps';
is_deeply +MockOutput->get_info, [['Reverting ', 'foo', ' from ', 'mydb']],
    'Should get info message about tag reversion';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag],
    [begin_revert_tag  => $tag],
    [commit_revert_tag  => $tag],
], 'Should have checked if the tag was deployed and reverted it';

# Try a tag that is not deployed.
$is_deployed_tag = 0;
ok $engine->revert($tag), 'Revert an undeployed tag';
is_deeply +MockOutput->get_info, [['Tag ', 'foo', ' is not deployed to ', 'mydb']],
    'Should get info message undeployed tag';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag],
], 'Should have checked if the tag was deployed';
$is_deployed_tag = 1;

# Add a step. (Re-create step so is_deeply works).
push @deployed_steps => $step;
ok $engine->revert($tag), 'Revert a tag with one step';
is_deeply +MockOutput->get_info, [
    ['Reverting ', 'foo', ' from ', 'mydb'],
    ['  - ', 'foo' ],
], 'Should get info message about tag and step reversion';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag],
    [begin_revert_tag  => $tag],
    [run_file => $step->revert_file ],
    [log_revert_step => $step ],
    [commit_revert_tag  => $tag],
], 'Should have reverted the step';

# Add another step. (Re-create step so is_deeply works).
$step2 = ref($step2)->new(name => $step2->name, tag => $tag );
push @deployed_steps => $step2;
ok $engine->revert($tag), 'Revert a tag with two steps';
is_deeply +MockOutput->get_info, [
    ['Reverting ', 'foo', ' from ', 'mydb'],
    ['  - ', 'bar' ],
    ['  - ', 'foo' ],
], 'Should revert steps in reverse order';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag],
    [begin_revert_tag  => $tag],
    [run_file => $step2->revert_file ],
    [log_revert_step => $step2 ],
    [run_file => $step->revert_file ],
    [log_revert_step => $step ],
    [commit_revert_tag  => $tag],
], 'Should have reverted both steps';

# Now die on tag reversion.
$mock->mock( commit_revert_tag => sub { die 'OMGWTF' } );
throws_ok { $engine->revert($tag) } qr/^FAIL\b/,
    'Should die on tag reversion failure';
is_deeply +MockOutput->get_info, [
    ['Reverting ', 'foo', ' from ', 'mydb'],
    ['  - ', 'bar' ],
    ['  - ', 'foo' ],
], 'Should get info message about tag and steps';
$debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message';
like $debug->[0][0], qr/^OMGWTF\b/, 'And it should be the original error';
is_deeply +MockOutput->get_fail, [
    ['Error removing tag ', $tag->name ]
], 'Should have the final failure message';
$mock->unmock('commit_revert_tag');

# Die on the first step reversion.
$mock->mock( log_revert_step => sub { die 'DONTTAZEME' });
throws_ok { $engine->revert($tag) } qr/^FAIL\b/,
    'Should die on step reversion failure';
is_deeply +MockOutput->get_info, [
    ['Reverting ', 'foo', ' from ', 'mydb'],
    ['  - ', 'bar' ],
], 'Should get info message about tag and first step';
$debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message';
like $debug->[0][0], qr/^DONTTAZEME\b/, 'And it should be the original error';
is_deeply +MockOutput->get_fail, [
    [
        'Error reverting step ', 'bar', $/,
        'The schema will need to be manually repaired'
    ],
], 'Should have the final failure message';

