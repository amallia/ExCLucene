#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include </usr/include/sys/stat.h>
#include <errno.h>

#include <iostream>
#include <iomanip>
#include <fstream>
#include <string>

#include <cuda_runtime.h>


#include "NewPFD_Decompression_kernel.cu"

using namespace std;


string dataset_dir = "/media/indexDisk/naiyong/dataset/";
string data_dir = "/media/indexDisk/naiyong/data/NewPFD/Compression/"; 
string result_dir = "/media/indexDisk/naiyong/result/NewPFD/Decompression/";


float FRAC = 0.0;
int step = 0;
ofstream ofsresult;


#define ITERATION 2
uint32_t batchID = 0;

unsigned char *ptr = NULL;       // pointer of queryset
at_search_ind_t *patind = NULL;  // pointer of struct for ind1 and ind2


#define BUFFER_SIZE 2048
unsigned char buffer[BUFFER_SIZE];
inline void readFile(unsigned char *ptr, FILE *fp) {
	uint64_t count = 0, bytes = 0;
	while ((bytes = fread(ptr+count, 1, BUFFER_SIZE, fp)) > 0) {
		count += bytes;
	}
}


void as_load_atind(const char *dbi_dir, const char *ind_name) {
	patind = (at_search_ind_t *)malloc(sizeof (*patind));
	struct stat buf;

	char file_name[MAX_PATH_LEN];
	patind->fd_ind1 = 0;
	patind->fd_ind2 = 0;
	patind->m_pind1 = 0;
	patind->m_pind2 = 0;

	// ind1
	sprintf (file_name, "%s%s.ind1", dbi_dir, ind_name);
	cout << "reading " << file_name << endl;
	stat(file_name, &buf);
	patind->sz_ind1 = buf.st_size;
	patind->m_tcount = buf.st_size / sizeof (at_term_ind1_t);
	patind->fd_ind1 = fopen(file_name, "rb");
	patind->m_pind1 = (at_term_ind1_t *)malloc(buf.st_size);
	readFile((unsigned char*)patind->m_pind1 , patind->fd_ind1);

	//ind2
	sprintf (file_name, "%s%s.ind2", dbi_dir, ind_name);
	cout << "reading " << file_name << endl;
	stat(file_name, &buf);
	patind->sz_ind2 = buf.st_size;
	patind->fd_ind2 = fopen(file_name,"rb");
	patind->m_pind2 = (unsigned char*) malloc(buf.st_size);
	readFile(patind->m_pind2 , patind->fd_ind2);
}



void allocateResource() {
	// host resources
	CUDA_SAFE_CALL(cudaMallocHost((void**)&h_queryID_perBlock, MAX_BLOCK_NUM * sizeof(uint16_t)));

	// device resources
	CUDA_SAFE_CALL(cudaMalloc((void**)&d_shortest_lists, baseSize));					
	CUDA_SAFE_CALL(cudaMalloc((void**)&d_segOffset, segOffset_size));				
	CUDA_SAFE_CALL(cudaMalloc((void**)&d_segHead, segHead_size));				

	CUDA_SAFE_CALL(cudaMalloc((void**)&d_lists, patind->sz_ind2));
	CUDA_SAFE_CALL(cudaMalloc((void**)&d_queryID_perBlock, MAX_BLOCK_NUM * sizeof(uint16_t)));

	if (!d_lists) {
		cout << "allocation failed" << endl;
		exit(1);
	}


	// transfer lists
	h_lists = (uint32_t *)patind->m_pind2;
	CUDA_SAFE_CALL(cudaMemcpy(d_lists, h_lists, patind->sz_ind2, cudaMemcpyHostToDevice));
	CUDA_SAFE_CALL(cudaMemcpy(d_segOffset, h_segOffset, segOffset_size, cudaMemcpyHostToDevice));	
	CUDA_SAFE_CALL(cudaMemcpy(d_segHead, h_segHead, segHead_size, cudaMemcpyHostToDevice));	
}


batchInfo CPUPreprocess(unsigned char *&ptr_in, const unsigned char *ptr_end) {
	batchInfo bi;			
	query_input_t input;
	testCell tc;	
	register uint32_t tcount = 0;

	uint32_t current_blockNum;		
	uint32_t ucntShortest_sum = 0; 
	uint32_t blockNum = 0;
	uint32_t nTotalQueryNum = 0;
	uint32_t queries_offset = 0;	// offset for h_queries

	while (ucntShortest_sum <= Threshold && ptr_in < ptr_end) {
		input.tnum = *ptr_in;
		ptr_in += sizeof(uint32_t);
		memcpy(input.tno, ptr_in, sizeof(uint32_t) * input.tnum);
		ptr_in += sizeof(uint32_t) * input.tnum;


		tc.tcount = input.tnum;
		tcount = tc.tcount;
		for (uint32_t i = 0; i < tcount; ++i) {
			at_term_ind1_t *pind1 = patind->m_pind1 + input.tno[i];
			tc.ucnt[i] = pind1->m_urlcount;  
			tc.uwlist[i] = (pind1->m_off) / sizeof(uint32_t);	
			tc.segNum[i] = *(h_segNum + input.tno[i]);
		}

		// insertion sort
		for (uint32_t i = 1; i < tcount; ++i) {
			uint32_t k = i;
			uint32_t uwlist_tmp = tc.uwlist[i];
			uint32_t ucnt_tmp = tc.ucnt[i];
			uint32_t segNum_tmp = tc.segNum[i];

			while (k && ucnt_tmp < tc.ucnt[k - 1]) {
				tc.uwlist[k] = tc.uwlist[k - 1];
				tc.ucnt[k] = tc.ucnt[k - 1];
				tc.segNum[k] = tc.segNum[k - 1];
				--k;
			};

			if (k != i) {
				tc.uwlist[k] = uwlist_tmp;
				tc.ucnt[k] = ucnt_tmp;
				tc.segNum[k] = segNum_tmp;
			}
		}

		// calculate block number needed by current query
		current_blockNum = tc.ucnt[0] % THREAD_NUM ? tc.ucnt[0] / THREAD_NUM + 1 : tc.ucnt[0] / THREAD_NUM;

		// set host memory for constant memory
		h_startBlockId[nTotalQueryNum] = blockNum;
		h_baseOffset[nTotalQueryNum] = ucntShortest_sum;
		h_queriesOffset[nTotalQueryNum] = queries_offset;

		// copy the query from tc to h_queries
		*(h_queries + queries_offset) = tc.tcount;
		*(h_queries + queries_offset + 1) = ucntShortest_sum;
		memcpy(h_queries + queries_offset + 2, tc.ucnt, sizeof(uint32_t) * tc.tcount);
		memcpy(h_queries + queries_offset + 2 + tc.tcount, tc.uwlist, sizeof(uint32_t) * tc.tcount);
		memcpy(h_queries + queries_offset + 2 + 2 * tc.tcount, tc.segNum, sizeof(uint32_t) * tc.tcount);
		// copy ends

		// set queryID for each block
		for (uint32_t k = 0; k < current_blockNum; ++k) {
			h_queryID_perBlock[blockNum + k] = nTotalQueryNum;	
		}

		// set several local variables for next loop
		blockNum += current_blockNum;
		ucntShortest_sum += tc.ucnt[0];
		queries_offset += tc.tcount * 3 + 2;
		++nTotalQueryNum;
	};


	if (baseSize / sizeof(uint32_t) < ucntShortest_sum) {
		cout << "ucntShortest_sum: " << ucntShortest_sum << "exceeds baseSize: " << baseSize << endl;
		exit(1);
	}

	if (MAX_BLOCK_NUM < blockNum) {
		cout << "blockNum is over " << MAX_BLOCK_NUM  << endl;;
		exit(1);
	}

	// prepare for return value
	bi.blockNum = blockNum;
	bi.constantUsedInByte = (nTotalQueryNum * 3 + queries_offset + batchInfoElementNum) * sizeof(uint32_t);  
	bi.ucntShortest_sum = ucntShortest_sum;
	bi.nTotalQueryNum = nTotalQueryNum;

	// integrate five arrays into h_constant
	memcpy(h_constant, &bi, sizeof(struct batchInfo));
	memcpy(h_constant + batchInfoElementNum, h_startBlockId, sizeof(uint32_t) * nTotalQueryNum);
	memcpy(h_constant + batchInfoElementNum + nTotalQueryNum, h_queriesOffset, sizeof(uint32_t) * nTotalQueryNum);
	memcpy(h_constant + batchInfoElementNum + nTotalQueryNum * 2, h_queries, queries_offset * sizeof(uint32_t));

	return bi;
}



void htodTransfer(const batchInfo &bi) {
	CUDA_SAFE_CALL(cudaMemcpyToSymbol(d_constant, h_constant, bi.constantUsedInByte));
	CUDA_SAFE_CALL(cudaMemcpy(d_queryID_perBlock, h_queryID_perBlock, bi.blockNum * sizeof(uint16_t), cudaMemcpyHostToDevice));
}


void kernelInvoke(const batchInfo &bi) {
#ifdef debug	
	printf("blockNum:%u\n",bi.blockNum);
#endif

	NewPFD_Decompression<<<bi.blockNum, THREAD_NUM>>>(d_lists, d_queryID_perBlock, d_shortest_lists, d_segOffset, d_segHead);
	CUDA_SAFE_CALL(cudaThreadSynchronize());


#ifdef debug
	if (batchID < 5) {
		// debug; transback h_isCommon and h_scan_odata
		FILE *fslist = fopen("slist", "a+");
		char slist[256];
		unsigned int *h_slist = (unsigned int *)malloc(baseSize);
		CUDA_SAFE_CALL(cudaMemcpy(h_slist, d_shortest_lists, baseSize, cudaMemcpyDeviceToHost));
		for (int i = 0; i < bi.ucntShortest_sum; ++i) {
			sprintf(slist, "batch:%d\ti:%d\t%d\n", batchID, i, h_slist[i]);
			fputs(slist, fslist);
			fflush(fslist);
		}
		free(h_slist);
		fclose(fslist);
		//debug ends
	}
#endif
}


void releaseResource() {
	free(h_segNum);
	h_segNum = NULL;

	free(h_segOffset);
	h_segOffset = NULL;

	free(h_segHead);
	h_segHead = NULL;

	CUDA_SAFE_CALL(cudaFreeHost(h_queryID_perBlock));
	h_queryID_perBlock = NULL;


	CUDA_SAFE_CALL(cudaFree(d_shortest_lists));
	d_shortest_lists = NULL;

	CUDA_SAFE_CALL(cudaFree(d_segOffset));
	d_segOffset = NULL;

	CUDA_SAFE_CALL(cudaFree(d_segHead));
	d_segHead = NULL;

	CUDA_SAFE_CALL(cudaFree(d_lists));
	d_lists = NULL;

	CUDA_SAFE_CALL(cudaFree(d_queryID_perBlock));
	d_queryID_perBlock = NULL;
}


template <uint64_t beginThreshold>
void Run(unsigned char *ptr_in, unsigned char *ptr_end) {
	Threshold = beginThreshold;

	batchInfo bi;
	unsigned char *ptr_in_old = ptr_in, *ptr_end_old = ptr_end;

	cudaEvent_t start, stop;
	float time_CPU = 0, time_htod = 0, time_kernel = 0;
	float elapsedTime = 0;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);


	cout << "begin decompressing..." << endl;
	if (Threshold < 1024 * 1024) 
		cout << "Threshold: " << Threshold / 1024 << "K";
	else 
		cout << "Threshold: " << Threshold / (1024 * 1024) << "M";

	cout << ", THREAD_NUM: " << THREAD_NUM << endl;

	allocateResource();

	uint32_t nTotalQueryNum = 0;
	uint32_t ucntShortest_sum = 0;
	for (int iteration = 0; iteration < ITERATION; ++iteration) {
		ptr_in = ptr_in_old;
		ptr_end = ptr_end_old;

		batchID = 0;
		nTotalQueryNum = 0;
		ucntShortest_sum = 0;
		while (ptr_in < ptr_end) {
			cudaEventRecord(start, 0);

			bi = CPUPreprocess(ptr_in, ptr_end);

			cudaEventRecord(stop, 0);
			cudaEventSynchronize(stop);
			cudaEventElapsedTime(&elapsedTime, start, stop);
			time_CPU += elapsedTime;

			cudaEventRecord(start, 0);

			htodTransfer(bi);

			cudaEventRecord(stop, 0);
			cudaEventSynchronize(stop);
			cudaEventElapsedTime(&elapsedTime, start, stop);
			time_htod += elapsedTime;


			cudaEventRecord(start, 0);

			kernelInvoke(bi);

			cudaEventRecord(stop, 0);
			cudaEventSynchronize(stop);
			cudaEventElapsedTime(&elapsedTime, start, stop);
			time_kernel += elapsedTime;


			++batchID;
			nTotalQueryNum += bi.nTotalQueryNum;
			ucntShortest_sum += bi.ucntShortest_sum;
		}
	}

	time_CPU /= ITERATION;
	time_htod /= ITERATION;
	time_kernel /= ITERATION;

	cout << "number of queries: " << nTotalQueryNum << endl;
	cout << "number of batches: " << batchID << endl;
	cout << "ucntShortest_sum: " << ucntShortest_sum << endl;
	cout << "CPU time: " <<  time_CPU << "ms" << endl
		 << "htod time: " <<  time_htod << "ms" << endl
		 << "kernel time: " <<  time_kernel << "ms" << endl << endl;

	float fThroughput = ucntShortest_sum / time_kernel * 1000;
	fThroughput /= 1024 * 1024 * 1024;
	ofsresult << FRAC << "\t" << fThroughput << endl;


	releaseResource();


	cudaEventDestroy(start);
	cudaEventDestroy(stop);
}


// Do some free operations
void terminator(){
	if (ptr != NULL) 
		free(ptr);
	if (patind->m_pind1 != NULL) 
		free(patind->m_pind1);
	if (patind->m_pind2 != NULL) 
		free(patind->m_pind2);
	if (patind != NULL) 
		free(patind);

	ptr = NULL;
	patind->m_pind1 = NULL;
	patind->m_pind2 = NULL;
	patind = NULL;
}


void runTest(int argc, char** argv) {
	if (argc < 2) {
		cout << "wrong number of arguments" << endl;
		exit(1);
	}
	string dataset = argv[1];

	if (argc > 2) {
		CUDA_SAFE_CALL(cudaSetDevice(strtol(argv[2], NULL, 10)));
	}
	else {
		CUDA_SAFE_CALL(cudaSetDevice(0));
	}


	string queryset = dataset_dir + dataset + "/" + dataset + ".query";
	char compindex_dir[MAX_PATH_LEN];
	char segNum_file[MAX_PATH_LEN];	
	char segOffset_file[MAX_PATH_LEN];	
	char segHead_file[MAX_PATH_LEN];		

	sprintf(compindex_dir, "%s%d/", data_dir.c_str(), step);
	sprintf(segNum_file, "%s%d/%s.segNum", data_dir.c_str(), step, dataset.c_str());
	sprintf(segOffset_file, "%s%d/%s.segOffset", data_dir.c_str(), step, dataset.c_str());
	sprintf(segHead_file, "%s%d/%s.segHead", data_dir.c_str(), step, dataset.c_str());


	struct stat buf;

	FILE *fsegNum = fopen(segNum_file, "rb");
	if (!fsegNum) {
		cout << segNum_file << " open failed\terr code: " << errno << endl;
		exit(1);
	}
	stat(segNum_file, &buf);
	h_segNum = (uint32_t *)malloc(buf.st_size);			
	readFile((unsigned char *)h_segNum, fsegNum);
	fclose(fsegNum);

	FILE *fsegOffset = fopen(segOffset_file, "rb");
	if (!fsegOffset) {
		cout << segOffset_file << " open failed\terr code: " << errno << endl;
		exit(1);
	}
	stat(segOffset_file, &buf);
	segOffset_size = buf.st_size;							
	h_segOffset = (uint32_t *)malloc(segOffset_size);	
	readFile((unsigned char *)h_segOffset, fsegOffset);
	fclose(fsegOffset);

	FILE *fsegHead = fopen(segHead_file, "rb");
	if (!fsegHead) {
		cout << segHead_file << " open failed\terr code: " << errno << endl;
		exit(1);
	}
	stat(segHead_file, &buf);
	segHead_size = buf.st_size;
	h_segHead = (uint32_t *)malloc(segHead_size);
	readFile((unsigned char *)h_segHead, fsegHead);
	fclose(fsegHead);

	FILE *fquery = fopen(queryset.c_str(),"rb");
	if (!fquery) {
		cout << queryset << " open failed\terr code: " << errno << endl;
		exit(1);
	}
	stat(queryset.c_str(), &buf);  
	uint32_t querysize = buf.st_size;
	ptr = (unsigned char *)malloc(querysize);					
	readFile(ptr, fquery);
	fclose(fquery);


	as_load_atind(compindex_dir, dataset.c_str());

	Run<1024 * 1024>(ptr, ptr + querysize);

	terminator();
	CUDA_SAFE_CALL(cudaThreadExit());
}


int main(int argc, char** argv)  {
	if (argc < 2) {
		cout << "wrong number of arguments" << endl;
		exit(1);
	}
	string dataset = argv[1];
	cout << "NewPFD_Decompression" << endl;
	cout << "dataset = " << dataset << endl;

	string result = result_dir + dataset + "_NewPFD_Decompression.txt";
	ofsresult.open(result.c_str());
	ofsresult << "Threshold = 1M" << endl;
	ofsresult << "Throughput: G docIDs/s" << endl << endl;
	ofsresult << "FRAC\tThroughput" << endl;

	float FRAC_begin = 0.0;
	float FRAC_step = 0.04;
	float FRAC_end = 0.64;
	for (step = 0, FRAC = FRAC_begin; FRAC <= FRAC_end; FRAC += FRAC_step) {
		cout << "step = " << step << ", FRAC = " << FRAC << endl;
		runTest(argc, argv);
		++step;
	}

	ofsresult.close();

	sleep(5);

	return 0;
}

