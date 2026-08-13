//%attributes = {"invisible":true,"preemptive":"capable"}
ASSERT:C1129(example_greeting("Miyako"; example_greeting_morning)="Good morning Miyako")
ASSERT:C1129(example_greeting("Miyako"; example_greeting_afternoon)="Good afternoon Miyako")
ASSERT:C1129(example_greeting("Miyako"; example_greeting_evening)="Good evening Miyako")
ASSERT:C1129(example_greeting("宮古"; example_greeting_morning)="Good morning 宮古")
ASSERT:C1129(example_greeting(""; example_greeting_morning)="Good morning ")

var $now : Time
$now:=Current time:C178
Case of 
	: ($now>=?03:00:00?) && ($now<?12:00:00?)
		ASSERT:C1129(example_greeting("Miyako"; example_greeting_default)="Good morning Miyako")
	: ($now>=?12:00:00?) && ($now<?18:00:00?)
		ASSERT:C1129(example_greeting("Miyako"; example_greeting_default)="Good afternoon Miyako")
	Else 
		ASSERT:C1129(example_greeting("Miyako"; example_greeting_default)="Good evening Miyako")
End case 