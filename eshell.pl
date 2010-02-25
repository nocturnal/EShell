use strict;

use File::Spec;
use File::Basename;
use Getopt::Long 2.36;
use XML::Simple;

use Storable qw( freeze thaw );
use MIME::Base64;

use constant VERSION => '2.2.7';

=pod

=head1 NAME

  eshell.pl -- Environment shell

=head1 SYNOPSIS

Creates a development environment with appropriate settings.

=head1 CONFIGURATION

=head2 Auto Update

EShell can be made to automatically update by setting the environment
variable 'ESHELL_AUTO_UPDATE_URL'.  This should be set to a url with
a file of the format:

  Version=<current authoritative version>
  URL=<url for an eshell of the above version>
  MD5=<md5 hash of contents of the linked eshell.pl>
  
Eg:

  Version=1.0.0
  URL=http://yourserver/eshell/1.0.0/eshell.pl
  MD5=bf84f903954450b88fb7785175290ff8

If EShell detects that it is older than the version specified in the
auto update file pointed to by ESHELL_AUTO_UPDATE_URL, it will
download the latest version from the specified URL and update itself.

=head2 Settings File Format


=head3 Includes

You can include other files using an include element, eg:

  <Include>some/other/file.xml</Include>
  
Includes are relative to the including file, or can be absolute paths.

You can also use environment variables in includes, eg:

  <Include path="%CODE_DIRECTORY%/SDKSubscriptions.xml" optional="1" />
  
The EShell will attempt to process this include once it has processed
the environment variables. Settings in the include files will not override
settings that have already been parsed.

=head3 Environment Variables

Environment variables can be set using this section of the
config file.  It consists of a set of 'EnvVar' elements.

Example:

  <EnvVar variableName="PERL_SIGNALS" value="unsafe" />

=head3 Environment Variable Aliases

You can specify aliases for environment variables that can be used on the
command line, eg:

  <EnvironmentVariableAlias aliasName="code" envVarName="PROJECT_CODE" />
  
Would cause the '-code' argument to the EShell to set the 'PROJECT_CODE'
environment varaible, eg:

  eshell.pl -settingsFile ... -code devel
  
Would set 'PROJECT_CODE' to be 'devel'.

=head3 Configs

Each config may contain a set of special Environment Variable overrides,
which override the Global Environment Variables defined in the ProjectSettings.

 <Config name="buildserver" parent="programmer" hidden="true" description="Are you a machine?">
 
You can then specify which config to load using the -config argument to EShell, eg:

 eshell.pl -settingsFile ... -config buildserver

Would use the "buildserver" Config  Environment Variables

 <Config name="buildserver" parent="programmer" hidden="true" description="Are you a machine?">
    <EnvVar variableName="SCE_PS3_ROOT" value="%IG_PROJECT_CODE%\sdk\cellsdk\cell" />
 </Config>
  
=cut


################################################################################
#
# Globals/Constants/ENV Setup
#

use constant DEFAULT_SHELL              => 'cmd.exe';  # default if no shell is set anywhere

my %g_EShellOptions = 
  (
    'config'          => undef,
    'executeCommand'  => 0,
    'runCommand'      => 0,
    'command'         => "",
    'settingsFile'    => undef,
    'shell'           => undef,
    'verbose'         => 0,
    'output'          => 0,
  );

my %g_UnhandledOptions; # options provided on the commandline that may be aliased in the file
my %g_EnvVarAliases;

my %g_SettingsFiles;    # to prevent recursive settings file includes

my %g_AvailableConfigs; # available configs
my $g_DefaultConfig = undef;
my %g_ParsingConfigs;   # to prevent parsing recursive configs

my %g_BackupEnv;        # the back up of the previous environment
my %g_SpecifiedEnvVars; # for holding env vars set from the command line, avoiding overrides
my %g_AllowOverrideEnvVars;  # for holding env vars which can be overridden by include files
my %g_NewEnv;           # for building the new environment

my %s_TypeProcessors = ( 'path' => \&ProcessPath );
my %g_ProcessingEnvVars;# to prevent cyclical EnvVar references
my %g_EnvVarTypes;      # for post processing special types of EnvVars using s_TypeProcessors

# we don't want to re-process certain variables
my %g_SkipProcessingVariables = (
                                  'ESHELL_COMMAND_LINE' => 1, 
                                );


################################################################################
my $returnValue = main();
if ( $returnValue )
{
  # try to sleep so they can see the message
  sleep( 3 );
}
exit( $returnValue );

sub main
{
  #
  # attempt to auto-update and restart
  #
  AutomaticUpdate();
  

  #
  # set up some general settings
  #
  SetupNewEnv();  
  
  
  #
  # parse commandline options
  #
  if ( !ParseCommandline() )
  {
    return 1;
  }

  
  #
  # parse the settings file(s)
  #  
  my $settingsFile = File::Spec->rel2abs( $g_EShellOptions{ 'settingsFile' } );

  if ( !ParseSettingsFile( $settingsFile, 0 ) )
  {
    return 0;
  }
  
  
  #
  # process the new environment variables and set %ENV
  #
  ProcessNewEnv();
  
  
  #
  # if we are testing, output the environment that would be set and exit
  #
  if ( $g_EShellOptions{ 'output' } )
  {
    my %newEnv;
    while ( my ( $key, $value ) = each %ENV )
    {
      $newEnv{ uc $key } = $value;
    }

    my %backupEnv;
    while ( my ( $key, $value ) = each %g_BackupEnv )
    {
      $backupEnv{ uc $key } = $value;
    }
    
    while ( my ( $key, $value ) = each %backupEnv )
    {
      print "set $key=\n" if ( !exists ( $newEnv{ $key } ) );
    }

    while ( my ( $key, $value ) = each %newEnv )
    {
      print "set $key=$value\n";
    }
    
    exit 0;
  }

  print "Insomniac Games EShell [Version " . VERSION . "]\n\n";


  #
  # Run/Exec the command or start the command prompt
  #
  if( $g_EShellOptions{'runCommand'} )
  {
    HideConsole();
    exec( $g_EShellOptions{ 'command' } );
  }
  elsif( $g_EShellOptions{'executeCommand'} )
  {
    system( $g_EShellOptions{ 'command' } );
    my $return_value = $? >> 8;
    return $return_value;
  }
  else
  {
    # we try to find the shell in the path and exec it
    # exec causes this perl script to exit and lets the shell take control
    # of input.  we do this so ctrl-c works correctly when trying to break


    # if they didn't define a shell using the command line, look in the project
    # and user settings...
    if ( !defined( $g_EShellOptions{'shell'} ) )
    {
      $g_EShellOptions{ 'shell' } = DEFAULT_SHELL;
    }

    my $command = $g_EShellOptions{ 'shell' };

    my $foundShell = 0;
    foreach my $pathDir ( split( ';', $ENV{PATH} ) )
    {
      if ( -e $command )
      {
        $foundShell = 1;
        last;
      }

      $command = File::Spec->catfile( $pathDir, $g_EShellOptions{'shell'} );
    }

    if ( $foundShell )
    {
      my $titleString = undef;

      if ( defined( $ENV{ ESHELL_TITLE } ) )
      {
        $titleString = ProcessValue( $ENV{ ESHELL_TITLE } );
      }
        
      if ( defined( $titleString ) )
      {
        require Win32::Console;
        Win32::Console::Title( $titleString );
      }
      
      $command = qq{"$command"}; # avoid problems with spaces

      exec( $command, @ARGV );
    }

    # if we got here, we couldn't find a shell, that's a problem...
    print STDERR "\nCould not locate a shell to execute! Attempted to use '" . $g_EShellOptions{'shell'} . "'\n\n";
    return 1;
  }

  return 0;
}

exit 0;


################################################################################
sub PrintUsage
{
  # get just the binary name, not the full path to it
  my $progname = $0;
  $progname =~ s/^.*\\(.*?)$/$1/;
  
  print qq{
  
Usage:
  $progname -settingsFile <file path> [-config <config name>]
            [-shell <shell path>] [-run <command>|-exec <command>]
            [-h|-help|-usage]

  -settingsFile    -- specify a settings file
  -config          -- specify the configuration to use as defined in
                       the settings file
  -shell           -- specify the shell to use (cmd.exe, 4nt.exe, etc.)
  -run             -- run a command, closing the console window
  -exec            -- execute a command without closing the console
  
  -stderr2stdout   -- redirect stderr to stdout
  
  -h|-help|-usage  -- display this help text
  
};
}

sub HideConsole()
{
  require Win32::API;

  # just for completeness...
  use constant SW_HIDE => 0;
  use constant SW_SHOWNORMAL => 1;

  # the API we need
  my $GetConsoleTitle = new Win32::API('kernel32', 'GetConsoleTitle', 'PN', 'N');
  my $SetConsoleTitle = new Win32::API('kernel32', 'SetConsoleTitle', 'P', 'N');
  my $FindWindow = new Win32::API('user32', 'FindWindow', 'PP', 'N');
  my $ShowWindow = new Win32::API('user32', 'ShowWindow', 'NN', 'N');

  # save the current console title
  my $old_title = " " x 1024;
  $GetConsoleTitle->Call( $old_title, 1024 );

  # build up a new (fake) title
  my $title = "PERL-$$-" . Win32::GetTickCount();

  # sets our string as the console title
  $SetConsoleTitle->Call( $title );

  # sleep 40 milliseconds to let Windows rename the window
  Win32::Sleep(40);

  # find the window by title
  my $hw = $FindWindow->Call( 0, $title );

  # restore the old title
  $SetConsoleTitle->Call( $old_title );

  # hide the console!
  $ShowWindow->Call( $hw, SW_HIDE );
}

################################################################################
sub SetupNewEnv
{
  %g_NewEnv = ();
  
  # Let environment know we're running in an eshell
  $g_NewEnv{ ESHELL } = VERSION;
  $g_NewEnv{ ENV_SHELL } = 1;

  # Unset this var so that P4 command lines still work
  # Perl sets PWD as the directory in which Perl was started in, and P4.exe will read
  # PWD instead of CD, breaking P4 commands that are context sensitive to the 
  # current working directory.
  $g_NewEnv{ PWD } = undef;
  
  #
  # initialize our new envrionment we'll be making, possibly from a backup
  #
  if ( defined( $ENV{ ESHELL_ENV_BACKUP } ) )
  {
    %g_BackupEnv = %{ thaw( decode_base64( $ENV{ ESHELL_ENV_BACKUP } ) ) };
    $g_NewEnv{ ESHELL_ENV_BACKUP } = $ENV{ ESHELL_ENV_BACKUP };
  }
  else
  {
    %g_BackupEnv = %ENV;

    $g_NewEnv{ ESHELL_ENV_BACKUP } = encode_base64( freeze( \%ENV ), '' );

    if ( length( $g_NewEnv{ ESHELL_ENV_BACKUP } ) > 8192 )
    {
      print STDERR ( "WARNING: Could not back up original environment due to size limitations.\n\n" );
      $g_NewEnv{ ESHELL_ENV_BACKUP } = undef;
    }
  }
}

################################################################################
sub ParseCommandline
{
  # store the command passed to eshell before parsing; useful for later reference
  $g_NewEnv{ ESHELL_COMMAND_LINE } = join( ' ', ( $0, @ARGV ) );
  
  my $getHelp = 0;

  my $initialOptionsParser = Getopt::Long::Parser->new();
  $initialOptionsParser->configure( "pass_through" );
  my $gotOptions = $initialOptionsParser->getoptions
  (
    "set=s"           => \&SetEnvironmentVarFromArgument,
    "settingsFile=s"  => \$g_EShellOptions{ 'settingsFile' },
    "config=s"        => \$g_EShellOptions{ 'config' },
    "exec=s"          => \$g_EShellOptions{ 'executeCommand' },
    "run=s"           => \$g_EShellOptions{ 'runCommand' },
    "shell=s"         => \$g_EShellOptions{ 'shell' },
    "stderr2stdout"   => sub { close(STDERR); open(STDERR, ">&STDOUT"); }, # useful for catching some things
    "h"               => \$getHelp,
    "help"            => \$getHelp,
    "usage"           => \$getHelp,
    "verbose"         => \$g_EShellOptions{ 'verbose' },
    "output"          => \$g_EShellOptions{ 'output' },
  );

  if ( !$gotOptions or $getHelp )
  {    
    PrintUsage(); 
    return 0;
  }

  while( my $key = shift( @ARGV ) )
  {
    last if ( $key eq '--' );
    
    my $value = shift( @ARGV );
    
    $key =~ s/^\-+//; # strip leading dashes
    
    $g_UnhandledOptions{ $key } = $value;
  }
  
  $g_EShellOptions{ 'command' } = $g_EShellOptions{ 'runCommand' } ? $g_EShellOptions{ 'runCommand' } : $g_EShellOptions{ 'executeCommand' };
  
  
  # set our settings file variable so things can know where they were read from
  $g_NewEnv{ ESHELL_SETTINGS_FILE } = $g_EShellOptions{ 'settingsFile' };
  
  return 1;
}

################################################################################
sub SetEnvironmentVarFromArgument
{
  my $envVarName;
  my $envVarValue;
  
  ( $envVarName, $envVarValue ) = split( '=', $_[1], 2 );
  $g_NewEnv{ $envVarName } = $envVarValue;
  $g_SpecifiedEnvVars{ $envVarName } = 1;
}

################################################################################
sub ParseSettingsFile
{
  my $filename = shift;
  my $isIncludeFile = shift;
  
  my $result = 1;

  if ( exists( $g_SettingsFiles{ $filename } ) )
  {
    PrintErrorAndExit( "Cyclical settings file includes found, already loaded: $filename.", 1 );
  }
  $g_SettingsFiles{ $filename } = 1;
  
  if ( !-e $filename )
  {
    PrintErrorAndExit( "Could not read settings file, it does not exist: $filename.", 1 );
  }
  
  my $newSettings = XMLin( $filename, ForceArray => [ 'Include', 'Config', 'EnvVar', 'EnvironmentVariableAlias', 'Shortcut' ] );

  if ( !defined( $newSettings ) )
  {
    PrintErrorAndExit( "Could not read settings file: $filename.", 1 );
  }

  #
  # set any aliased environment variables
  #
  if ( exists( $newSettings->{ EnvironmentVariableAlias } ) )
  {
    foreach my $alias ( @{ $newSettings->{ EnvironmentVariableAlias } } )
    {
      $g_EnvVarAliases{ $alias->{ aliasName } } = $alias->{ envVarName };
      
      if ( exists( $g_UnhandledOptions{ $alias->{ aliasName } } ) )
      {
        $g_NewEnv{ $alias->{ envVarName } } = $g_UnhandledOptions{ $alias->{ aliasName } };
        $g_SpecifiedEnvVars{ $alias->{ envVarName } } = 1;
        delete( $g_UnhandledOptions{ $alias->{ aliasName } } );
      }
    }
  }

  my $configFileDirectory = dirname( $filename );
  
  #
  # set up environment variables
  #
  ParseEnvVars( $newSettings->{ EnvVar }, $isIncludeFile ? 0 : 1 );

  #
  # append only the new configs found in the settings file
  #
  foreach my $configName ( keys %{ $newSettings->{ Config } } )
  {
    if ( !exists $g_AvailableConfigs{ $configName } )
    {
      $g_AvailableConfigs{ $configName } = $newSettings->{ Config }{ $configName };
      
      my $isDefault = exists( $g_AvailableConfigs{ $configName }->{default} ) ? $g_AvailableConfigs{ $configName }->{default} : 0 ;
      $isDefault = ( $isDefault == 1 or $isDefault eq "true" ) ? 1 : 0 ;
      if ( $isDefault )
      {
        if ( !defined $g_DefaultConfig )
        {
          $g_DefaultConfig = $configName;
        }
      }
    }
  }
  
  #
  # parse includes
  #
  if ( exists( $newSettings->{ Include } ) )
  {
    ParseIncludes( $newSettings->{ Include }, $configFileDirectory );
  }
  
  #
  # parse a named configuration from the root settings file
  #
  if ( not $isIncludeFile )
  {
    if ( !defined $g_EShellOptions{ 'config' } )
    {
      $g_EShellOptions{ 'config' } = $g_DefaultConfig;
    }
    
    if ( exists( $g_AvailableConfigs{ $g_EShellOptions{ 'config' } } ) )
    {
      # recursively process configs
      ParseConfig( \%g_AvailableConfigs, $g_AvailableConfigs{ $g_EShellOptions{ 'config' } }, $configFileDirectory, $g_EShellOptions{ 'config' } );
    }
  }
  
  return $result;
}

################################################################################
## Parse an Include element; settings parsed from this file will *NOT* override
## those in the root ProjectSettings file.
##
## Example:
##  <Include>%IG_PROJECT_CODE%\%IG_GAME%\config\GameSettings.xml</Include>
## OR:
##  <Include path="%IG_PROJECT_TOOLS%\config\ReleaseSettingsWEWEWE.xml" optional="1" />
##
sub ParseIncludes
{
  my $includes = shift;
  my $configFileDirectory = shift;

  my $result = 1;
  foreach my $include ( @{ $includes } )
  {
    my $includePath = undef;
    my $optional = 0;
    if ( defined( $include ) and ( ref( $include ) eq 'HASH' ) )
    {
      $includePath = exists( $include->{path} ) ? $include->{path} : undef ;      
      if ( exists( $include->{ optional } ) 
        and ( ( $include->{ optional } == 1 ) or ( $include->{ optional } eq "1" ) ) )
      {
        $optional = 1;
      }
    }
    else
    {
      $includePath = $include;
    }
    #print ( "Including ($optional) $includePath\n" );
    
    # process the include path as best we can
    $includePath = ProcessValue( $includePath );
    
    if ( $includePath =~ /\%.*?\%/ )
    {
      if ( not $optional )
    {
        PrintErrorAndExit( "Could not load required include file, the path contains undefined environment variable(s): $include.", 1 );
      }
      
      next;
    }
    
    $includePath = File::Spec->rel2abs( $includePath, $configFileDirectory );
    
    if ( !-e $includePath )
    {
      if ( not $optional )
      {
        PrintErrorAndExit( "Could not read required include file, it does not exist: $includePath.", 1 );
      }
      
      next;
    }
    
    $result &= ParseSettingsFile( $includePath, 1 );
  }
  
  return $result;
}

################################################################################
## Parse a Config element, it's EnvVars will override those defined globally in 
## the ProjectSettings element.
##
## Example:
##  <Config name="buildserver" parent="programmer" hidden="true" description="Are you a machine?">
##
sub ParseConfig
{
  my $configs = shift;
  my $config = shift;
  my $configDirectory = shift;
  my $configName = shift;

  if ( exists( $g_ParsingConfigs{ $configName } ) )
  {
    PrintErrorAndExit( "Cyclical configurations found; already loaded configuration: \"$configName\".", 1 );
  }
  $g_ParsingConfigs{ $configName } = 1;

  if ( exists( $config->{ parent } ) )
  {
    if ( exists( $configs->{ $config->{ parent } } ) )
    {
      if ( exists( $g_ParsingConfigs{ $config->{ parent } } ) )
      {
        PrintErrorAndExit( "Cyclical configurations found; \"$configName\" references an already loaded parent configuration: \"$config->{ parent }\".", 1 );
      }

      ParseConfig( $configs, $configs->{ $config->{ parent } }, $configDirectory, $config->{ parent } );
    }
    else
    {
      print STDERR ( "WARNING: Configuration \"$configName\" references undefined parent configuration: \"$config->{ parent }\".\n\n" );
    }
  }

  if ( exists( $config->{EnvVar} ) )
  {
    ParseEnvVars( $config->{EnvVar}, 1 );
  }
  
  #if ( exists( $config->{EShell} ) )
  #{
  #  ParseEShell( $config->{EShell} );
  #}
  
  delete( $g_ParsingConfigs{ $configName } );
}

################################################################################
## Parse an EShell element
##
## Example:
##   <EShell>
##     <Shortcut>...</Shortcut>
##
sub ParseEShell
{  
  my $eshellRef = shift or return undef;

  if ( exists( $eshellRef->{ Shortcut } ) )
  {
    foreach my $shortcut ( @{ $eshellRef->{ Shortcut } } )
    {
      #ParseShortcut( $shortcut );
    }
  }
}

################################################################################
## Parse an EnvVar element; these will be used to create the local environment.
##
## Example:
##  <EnvVar variableName="IG_TOOLS_SYMBOLS_STORE" value="\\locutus\toolshed\symbols" type="path" override="0" />
##
sub ParseEnvVars
{  
  my $envVarsRef = shift or return undef;
  my $override = shift;

  foreach my $envVar (@{$envVarsRef})
  {
    # skip processing any env vars that were specified on the command line
    if ( exists( $g_SpecifiedEnvVars{ $envVar->{ variableName } } ) )
    {
      next;
    }
  
    # if they care about override and they've said 'don't override my existing variable" *and*... 
    # that variable exists in the g_BackupEnv, use that value and continue
    if ( ( exists( $envVar->{ override } ) && $envVar->{ override } == 0 )
      && ( defined $g_BackupEnv{ $envVar->{ variableName } } ) )
    {
      $g_NewEnv{ $envVar->{ variableName } } = $g_BackupEnv{ $envVar->{ variableName } };
      next;
    }
    if ( exists( $g_AllowOverrideEnvVars{ $envVar->{ variableName } } ) )
    {
      # override="1" was passed
      #print "Overridding $envVar->{ variableName }\n";
    }
    elsif ( $override == 0 && defined( $g_NewEnv{ $envVar->{ variableName } } ) )
    {
      next;
    }
        
    my $value = undef;
    
    if ( defined( $envVar->{ value } ) )
    {
      $value = $envVar->{value};
    }

    # dirty undocumented feature
    if ( defined( $envVar->{ process } ) )
    {
      eval $envVar->{ process };
      
      if ( $@ )
      {
        print STDERR ( "WARNING: $@\n\n" );
      }
    }
    
    if ( defined( $envVar->{ type } ) )
    {
      $g_EnvVarTypes{ $envVar->{ variableName } } = $envVar->{ type };
    }
    
    $g_NewEnv{ $envVar->{ variableName } } = $value;
    
    if ( exists( $envVar->{ allow_override } ) 
      and ( ( $envVar->{ allow_override } == 1 ) or ( $envVar->{ allow_override } eq "1" ) ) )
    {
      $g_AllowOverrideEnvVars{ $envVar->{ variableName } } = 1;
    }
  }
}

################################################################################
## Recursively replaces win32-style environment variable tokens with the values 
## of those defined in the new environment.
##
## Example:
##  ProcessValue( "%CODE_DIRECTORY%/Include.xml" ); #returns "C:/code/Include.xml"
##
sub ProcessValue
{
  my $value = shift;
  my $newValue = $value;

  # has a win32-style env var in it
  while( $newValue =~ /\%(.*?)\%/ )
  {
    my $envVarName = $1;

    my $replacement = ProcessEnvVar( $envVarName );
    $newValue =~ s/\%$envVarName\%/$replacement/g;
  }

  return $newValue;
}

###################################################################
## Post processing for environment variables that define paths
##
sub ProcessPath
{
  my $value = shift;
  
  return File::Spec->canonpath( $value );
}

################################################################################
## Recursively replaces win32-style environment variable tokens with the values 
## of those defined in the new environment; as well as any post processing 
## needed based on the environment variable type.
##
## Example:
##  <EnvVar variableName="ROOT" value="C:" />
##  <EnvVar variableName="CODE_DIRECTORY" value="%ROOT%/code" />
##  ...
##
##  ProcessEnvVar( "CODE_DIRECTORY" ); # returns "C:/code"
##
sub ProcessEnvVar
{  
  my $varName = shift or return undef;

  my $varValue = $g_NewEnv{ $varName };
  
  if ( !defined $varValue )
  {
    $varValue = $g_BackupEnv{ $varName };
  }

  # avoid errors re unset values
  if ( !defined $varValue )
  {
    PrintErrorAndExit( "Could not process the value for an undefined environment variable: \"$varName\".", 1 );
  }
  
  # has a win32-style env var in it
  if ( $varValue =~ /\%.*?\%/ )
  {
    if ( exists( $g_ProcessingEnvVars{ $varName } ) )
    {
      PrintErrorAndExit( "Cyclical environment variable reference found for \"$varName\".", 1 );
    }
    $g_ProcessingEnvVars{ $varName } = 1;
  
    while( $varValue =~ /\%(.*?)\%/ )
    {
      my $replaceVarName = $1;
      my $replaceVarValue = '';
      
      if ( $varName eq $replaceVarName )
      {
        if ( defined $g_BackupEnv{ $varName } )
        {
          $replaceVarValue = $g_BackupEnv{ $varName };
        }
      }
      elsif ( exists( $g_ProcessingEnvVars{ $replaceVarName } ) )
      {
        PrintErrorAndExit( "Cyclical environment variable reference found; caused by \"$varName\" referencing \"$replaceVarName\".", 1 );
      }
      elsif ( !defined $g_NewEnv{ $replaceVarName } && !defined $g_BackupEnv{ $replaceVarName } )
      {
        PrintErrorAndExit( "Environment variable \"$varName\" references an undefined environment variable \"$replaceVarName\".", 1 );
      }
      else
      {
        $replaceVarValue = ProcessEnvVar( $replaceVarName );
      }
      
      $varValue =~ s/\%$replaceVarName\%/$replaceVarValue/g;
    }
   
    # Post processing by environment variable type
    if ( exists( $g_EnvVarTypes{ $varName } ) )
    {
      $varValue = $s_TypeProcessors{ $g_EnvVarTypes{ $varName } }->( $varValue );
    }

    delete( $g_ProcessingEnvVars{ $varName } );
  }
  
  return $varValue;
}

################################################################################
## Process the new environment variables and set %ENV
##
sub ProcessNewEnv
{

  #for my $key ( sort keys %g_NewEnv ) { print "$key=$g_NewEnv{$key}\n"; }die; 
  foreach my $varName ( keys( %g_NewEnv ) )
  {
    if ( defined $g_NewEnv{ $varName } && !exists( $g_SkipProcessingVariables{ $varName } ) )
    {
      $g_NewEnv{ $varName } = ProcessEnvVar( $varName );
    }
  }
  
  %ENV = ( %g_BackupEnv, %g_NewEnv );
}

################################################################################
sub PrintErrorAndExit
{
  my $printStr = shift;
  my $exitValue = shift;
  
  print STDERR ( "\nERROR: " . $printStr . "\n\n" );
  
  # try to sleep so they can see the message
  sleep( 3 );
  
  if ( !defined $exitValue )
  { 
    $exitValue = 1;
  }
  exit( $exitValue );
}


################################################################################
## Auto update
##
sub AutomaticUpdate
{
  if ( !defined( $ENV{ ESHELL_AUTO_UPDATE_URL } ) )
  {
    return;
  }

  eval 'use LWP::UserAgent;';
  if ( $@ )
  {
    print STDERR ( "WARNING: Could not check for updates because you don't have LWP::UserAgent support.\n\n" );
    return;
  }

  my $ua = LWP::UserAgent->new;
  $ua->timeout(3);
  $ua->env_proxy;
  
  my $response = $ua->get( $ENV{ ESHELL_AUTO_UPDATE_URL } );

  if ( !$response->is_success )
  {
    print "Could not obtain auto-update info: " . $response->status_line . "\n";
    return;
  }

  my $updateInfo = $response->content . "\n"; # add a newline to make parsing a little easier
  my ( $version ) = $updateInfo =~ /version\s*=\s*(.*?)\s+/is;
  my ( $url ) = $updateInfo =~ /url\s*=\s*(.*?)\s+/is;
  my ( $md5 ) = $updateInfo =~ /md5\s*=\s*(.*?)\s+/is;
  my ( $force ) = $updateInfo =~ /force\s*=\s*(.*?)\s+/is;
  
  chomp( $version );
  chomp( $url );
  chomp( $md5 );
  chomp( $force );
  
  my $remoteVersion = sprintf( "%03d%03d%03d", split( '\.', $version ) );
  my $localVersion = sprintf( "%03d%03d%03d", split( '\.', VERSION ) );
  
  # up to date in this case
  if ( !$force and ( !defined( $version ) or $localVersion >= $remoteVersion ) )
  {
    return;
  }
  
  use Digest::MD5;
  use File::Temp;
  
  my $tempFilename = File::Temp::tmpnam();

  # download to a temp file
  $response = $ua->get( $url, ':content_file' => $tempFilename );
  
  # we might fail... oh well, try again next time
  if ( !$response->is_success )
  {
    unlink( $tempFilename );
    return;
  }
  
  my $tempMd5 = Digest::MD5->new();
  
  my $tempFile = undef;
  open( $tempFile, "<$tempFilename" );
  $tempMd5->addfile( $tempFile );
  close( $tempFile );
  
  my $sig = $tempMd5->hexdigest();
  
  if ( $sig ne $md5 )
  {
    print qq{
  Signature mismatch on downloaded update, update NOT applied (will try again next time).
    Signature: $sig
    Authoritative: $md5
};
    unlink( $tempFilename );
    return;
  }

# it would be awesome if just using File::Copy worked... windows sucks.  
#  use File::Copy;
#  File::Copy::move( $tempFilename, $0 );

  open( NEWSHELL, "<$tempFilename" );
  my @contents = <NEWSHELL>;
  close( NEWSHELL );
  unlink( $tempFilename ); # shouldn't need this file anymore
  
  chomp( @contents );
  
  if( !open( ESHELL, ">$0" ) )
  {
    print "Could not open $0 for writing for automatic update. This is probably a serious problem and you should contact your IT staff.\n";
    return;
  }
  
  print ESHELL join( "\n", @contents );
  close( ESHELL );
  
  print "Automatically updated to version $version\n";
  sleep( 1 );
  
  # launch the new version and kill the current one
  exec( qq{ "$0" } . ' ' . join( ' ', @ARGV ) );
  exit;
}


=pod

=head1 AUTHOR

EShell is developed primarily at Insomniac Games, Inc. with contributors:

Andrew Burke E<lt>aburke@insomniacgames.comE<gt>
             E<lt>aburke@bitflood.orgE<gt>
             
Rachel Mark E<lt>rachel@insomniacgames.comE<gt>

=head1 COPYRIGHT

This script is free software.  You can redistribute it and/or modify it 
under the same terms as Perl itself.

=cut

