/*
 * xu_ddr_probe.c -- Phase 1 hardware verification tool. THROWAWAY, not
 * part of Phase 3's real xu.cpp -- see
 * /Users/faye/.claude/plans/keen-sauteeing-dolphin.md.
 *
 * Run on the MiSTer's own ARM/Linux side (root@mister) after flashing a
 * PDP2011 build with rtl/xu_test_stub.vhd wired in place of the real SPI
 * decoder. Confirms xu_ddr_mailbox.vhd's CDC/offset-table mechanism works
 * end to end, bidirectionally, against real hardware:
 *
 *   1. read the TX buffer at offset 0x0000, confirm it matches the
 *      stub's known test pattern byte-for-byte
 *   2. read ETXST (0x6018) / ETXLEN (0x6020), confirm they match what the
 *      stub wrote (0x0000 / 8)
 *   3. poll TXRTS_REQ (0x6008) until it reads 1
 *   4. write TXRTS_DONE=1 (0x6010) -- this probe's own field, sole
 *      writer, exactly what xud will eventually do
 *   5. poll TXRTS_REQ until the stub clears it back to 0, confirming the
 *      stub observed TXRTS_DONE and completed the handshake on its own
 *      terms
 *
 * Uses /dev/mem + O_SYNC + mmap(), copying shmem.cpp's real, proven
 * pattern (Main_MiSTer's minimig_a2065/shmem.cpp) -- this is a separate
 * process from Main_MiSTer, so it can't call the compiled-in shmem_map()
 * directly.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define WINDOW_BASE   0x1FF00000UL
#define WINDOW_SIZE   0x10000UL   /* 64KB */

#define OFF_TX_BUF        0x0000
#define OFF_TXRTS_REQ     0x6008
#define OFF_TXRTS_DONE    0x6010
#define OFF_ETXST         0x6018
#define OFF_ETXLEN        0x6020

static const uint64_t TEST_PATTERN = 0xDEADBEEFCAFEBABEULL;

static volatile uint8_t *win;

static uint64_t rd64(unsigned long off)
{
	uint64_t v;
	memcpy(&v, (const void *)(win + off), 8);
	return v;
}

static void wr64(unsigned long off, uint64_t v)
{
	memcpy((void *)(win + off), &v, 8);
}

int main(void)
{
	int fd;
	int poll_count;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("open /dev/mem");
		return 1;
	}

	win = mmap(NULL, WINDOW_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
	           fd, WINDOW_BASE);
	if (win == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	/* 1. TX buffer pattern */
	uint64_t pattern = rd64(OFF_TX_BUF);
	if (pattern != TEST_PATTERN) {
		fprintf(stderr, "FAIL: TX buffer mismatch: got %016llx, "
		        "want %016llx\n",
		        (unsigned long long)pattern,
		        (unsigned long long)TEST_PATTERN);
		goto fail;
	}
	printf("PASS: TX buffer pattern matches (%016llx)\n",
	       (unsigned long long)pattern);

	/* 2. ETXST / ETXLEN */
	uint64_t etxst = rd64(OFF_ETXST);
	uint64_t etxlen = rd64(OFF_ETXLEN);
	if (etxst != 0 || etxlen != 8) {
		fprintf(stderr, "FAIL: ETXST/ETXLEN mismatch: "
		        "etxst=%llu etxlen=%llu, want 0/8\n",
		        (unsigned long long)etxst,
		        (unsigned long long)etxlen);
		goto fail;
	}
	printf("PASS: ETXST=0x%llx ETXLEN=%llu\n",
	       (unsigned long long)etxst, (unsigned long long)etxlen);

	/* 3. wait for TXRTS_REQ to go 1 */
	for (poll_count = 0; poll_count < 1000000; poll_count++) {
		if (rd64(OFF_TXRTS_REQ) & 1)
			break;
	}
	if (!(rd64(OFF_TXRTS_REQ) & 1)) {
		fprintf(stderr, "FAIL: TXRTS_REQ never went 1\n");
		goto fail;
	}
	printf("PASS: observed TXRTS_REQ=1 after %d polls\n", poll_count);

	/* 4. write TXRTS_DONE=1, this probe's own field */
	wr64(OFF_TXRTS_DONE, 1);
	printf("wrote TXRTS_DONE=1\n");

	/* 5. wait for the stub to clear TXRTS_REQ back to 0 */
	for (poll_count = 0; poll_count < 1000000; poll_count++) {
		if (!(rd64(OFF_TXRTS_REQ) & 1))
			break;
	}
	if (rd64(OFF_TXRTS_REQ) & 1) {
		fprintf(stderr, "FAIL: TXRTS_REQ never cleared -- stub did "
		        "not complete the handshake\n");
		goto fail;
	}
	printf("PASS: stub cleared TXRTS_REQ after %d polls -- "
	       "bidirectional round trip complete\n", poll_count);

	/* stub is sole writer of TXRTS_DONE too; clear it back to 0 so a
	 * re-run of this probe starts from a clean state. */
	wr64(OFF_TXRTS_DONE, 0);

	munmap((void *)win, WINDOW_SIZE);
	close(fd);
	printf("ALL PASS\n");
	return 0;

fail:
	munmap((void *)win, WINDOW_SIZE);
	close(fd);
	return 1;
}
