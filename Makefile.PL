use 5.008;
use ExtUtils::MakeMaker;
WriteMakefile
  (
   'NAME'		=> 'optimizer',
   'VERSION_FROM'	=> 'optimizer.pm',
   'PREREQ_PM'	=>
   {	DynaLoader   => 0,
	'B::Generate' => 0},
   ABSTRACT_FROM => 'optimizer.pm',
   AUTHOR     => 'Simon Cozens, Arthur Bergman, Reini Urban'
  );

sub MY::depend { "README : optimizer.pm\n\tpod2text optimizer.pm > README\n"; }
