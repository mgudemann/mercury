#define r1		count_usage(1, mr1)
#define r2		count_usage(2, mr2)
#define r3		count_usage(3, mr3)
#define r4		count_usage(4, mr4)
#define r5		count_usage(5, mr7)
#define r6		count_usage(6, mr10)
#define r7		count_usage(7, mr11)
#define r8		count_usage(8, mr12)
#define r9		count_usage(9, mr13)
#define r10		count_usage(10, mr14)
#define r11		count_usage(11, mr15)
#define r12		count_usage(12, mr16)
#define r13		count_usage(13, mr17)
#define r14		count_usage(14, mr18)
#define r15		count_usage(15, mr19)
#define r16		count_usage(16, mr20)
#define r17		count_usage(17, mr21)
#define r18		count_usage(18, mr22)
#define r19		count_usage(19, mr23)
#define r20		count_usage(20, mr24)
#define r21		count_usage(21, mr25)
#define r22		count_usage(22, mr26)
#define r23		count_usage(23, mr27)
#define r24		count_usage(24, mr28)
#define r25		count_usage(25, mr29)
#define r26		count_usage(26, mr30)
#define r27		count_usage(27, mr31)
#define r28		count_usage(28, mr32)
#define r29		count_usage(29, mr33)
#define r30		count_usage(30, mr34)
#define r31		count_usage(31, mr35)
#define r32		count_usage(32, mr36)

#define succip		LVALUE_CAST(Code *, count_usage(SI_RN, mr0))
#define hp		LVALUE_CAST(Word *, count_usage(HP_RN, mr5))
#define sp		LVALUE_CAST(Word *, count_usage(SP_RN, mr6))
#define curfr		LVALUE_CAST(Word *, count_usage(CF_RN, mr8))
#define maxfr		LVALUE_CAST(Word *, count_usage(MF_RN, mr9))

#define VIRTUAL_REG_MAP_BODY	{\
	0,\
	1,\
	2,\
	3,\
	4,\
	5,\
	6,\
	7,\
	8,\
	9,\
	10,\
	11,\
	12,\
	13,\
	14,\
	15,\
	16,\
	17,\
	18,\
	19,\
	20,\
	21,\
	22,\
	23,\
	24,\
	25,\
	26,\
	27,\
	28,\
	29,\
	30,\
	31,\
	32,\
	33,\
	34,\
	35,\
	36,\
	37,\
	38,\
	39,\
	40,\
	41,\
	42,\
	43,\
	44,\
	45,\
	46,\
	47,\
	48,\
	49,\
	50,\
	51,\
	52,\
	53,\
	54,\
	55,\
	56,\
	57,\
	58,\
	59,\
	60,\
	61,\
	62,\
	63,\
	64,\
}
