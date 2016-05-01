/*
 * Acid Cam v2 - OpenCV Edition
 * written by Jared Bruni ( http://lostsidedead.com )
 * GPL
 *
 *	 ac2 arguments:
 *	 -t transition [Transition variable]
 *	 -l input_file.avi [Use video instead of camera]
 *	 -d device [Capture device index]
 *	 -x  [Disable recording]
 *	 -f fps [Frames per second]
 *	 -p alpha [Second pass alpha level]
 *	 -o output.avi [Output avi filename]
 *	 -s seed [Random generator seed]
 *	 -i imgfile.jpg [Image for blend with image functions]
 *	 -v imglist.txt [Image list for image functions]
 *	 -w width [Webcam Resolution Width]
 *	 -h height [Webcam Resolution Height]
 *   -a output_name [Save file prefix]
 *
 *   To compile use:
 *   $ g++ -O3 fractal.cpp ac.cpp main.cc -o ac2 `pkg-config opencv --cflags --libs`
 *
 */

#import"ac.h"
#import"videocapture.h"
#import"AC_Controller.h"
#include<fstream>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
unsigned int int_Seed = (unsigned int)(time(0));
bool breakProgram = false, programRunning = false, stopProgram = false;
unsigned int total_frames = 0;

void ProcFrame(cv::Mat &frame);
void BuildImages(std::string filename);
void TrackbarCallback(int pos, void *ptr);
void IsNegativeCallback(int pos, void *ptr);
void IsNegativeFlash(int pos, void *ptr);
void Pass2Enable(int pos, void *ptr);
void ReverseColors(int pos, void *ptr);
void SlideShow(int pos, void *ptr);
void SlideRand(int pos, void *ptr);
void StrobeIt(int pos, void *ptr);
void BlurFirst(int pos, void *ptr);
void BlurSecond(int pos, void *ptr);

cv::VideoCapture capture;
int frame_cnt, key;

/*** CoreAudio ***/

const int kNumberRecordBuffers = 3;


typedef struct Recorder {
    AudioFileID recordFile;
    SInt64 recordPacket;
    Boolean running;
} Recorder;

void CopyEncoderCookieToFile(AudioQueueRef queue, AudioFileID theFile);
void Error(OSStatus error, const char *operation);
OSStatus GetDefaultInputDeviceSampleRate(Float64 *outSampleRate);

void Error(OSStatus error, const char *operation) {
    if(error == noErr) return;
    char errorString[20];
    *(UInt32 *)(errorString +1) = CFSwapInt32HostToBig(error);
    if(isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4])) {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else {
        sprintf(errorString, "%d", (int) error);
        fprintf(stderr, "Error: %s (%s)\n", operation, errorString);
        exit(-1);
    }
}

OSStatus GetDefaultInputDeviceSampleRate(Float64 *outSampleRate) {
    OSStatus error;
    AudioDeviceID deviceID = 0;
    AudioObjectPropertyAddress propAddress;
    UInt32 propertySize;
    propAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = 0;
    propertySize = sizeof(AudioDeviceID);
    error = AudioHardwareServiceGetPropertyData(kAudioObjectSystemObject, &propAddress, 0, NULL, &propertySize, &deviceID);
    
    if(error) return error;
    propAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
    propAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propAddress.mElement = 0;
    propertySize = sizeof(Float64);
    error = AudioHardwareServiceGetPropertyData(deviceID, &propAddress, 0, NULL, &propertySize, outSampleRate);
    return error;
}


void CopyEncoderCookieToFile(AudioQueueRef queue, AudioFileID theFile) {
    
    OSStatus error; UInt32 propertySize;
    error = AudioQueueGetPropertySize(queue, kAudioConverterCompressionMagicCookie,&propertySize);
    if (error == noErr && propertySize > 0)
    {
        Byte *magicCookie = (Byte *)malloc(propertySize);
        Error(AudioQueueGetProperty(queue, kAudioQueueProperty_MagicCookie, magicCookie,&propertySize),"Couldn't get audio queue's magic cookie");
        Error(AudioFileSetProperty(theFile, kAudioFilePropertyMagicCookieData, propertySize,magicCookie), "Couldn't set audio file's magic cookie");
        
        free(magicCookie);
    }
}

int ComputeRecordBufferSize(const AudioStreamBasicDescription *format, AudioQueueRef queue, float seconds) {
    int packets, frames, bytes;
    frames = (int) ceil(seconds * format->mSampleRate);
    if(format->mBytesPerFrame > 0)
        bytes = frames * format->mBytesPerFrame;
    else {
        UInt32 maxPacketSize;
        if(format->mBytesPerPacket > 0)
            maxPacketSize = format->mBytesPerPacket;
        else {
            UInt32 propertySize = sizeof(maxPacketSize);
            Error(AudioQueueGetProperty(queue, kAudioConverterPropertyMaximumOutputPacketSize, &maxPacketSize, &propertySize), "Could not get queue's maximum output packet size");
        }
        if(format->mFramesPerPacket > 0)
            packets = frames / format->mFramesPerPacket;
        else
            packets = frames;
        
        if(packets == 0)
            packets = 1;
        
        bytes = packets * maxPacketSize;
    }
    
    return bytes;
}


void InputCallback(void *userData, AudioQueueRef inque, AudioQueueBufferRef inbuf, const AudioTimeStamp *startTime,
                   UInt32 numPackets, const AudioStreamPacketDescription *inpacket) {
    Recorder *recorder = (Recorder *)userData;
    if(numPackets > 0) {
        Error(AudioFileWritePackets(recorder->recordFile, FALSE,inbuf->mAudioDataByteSize, inpacket, recorder->recordPacket, &numPackets, inbuf->mAudioData), "AudioFileWrite Packets Failed");
        
        recorder->recordPacket += numPackets;
    }
    
    if(recorder->running) {
        Error(AudioQueueEnqueueBuffer(inque, inbuf, 0, NULL), "AudioQeueEnqueueBuffer Failed");
    }
}

Recorder recorder;
AudioQueueRef queue = {0};

void startRecord(const char *filename) {
    memset(&recorder, 0, sizeof(Recorder));
    AudioStreamBasicDescription recordFormat;
    memset(&recordFormat, 0, sizeof(recordFormat));
    recordFormat.mFormatID = kAudioFormatMPEG4AAC;
    recordFormat.mChannelsPerFrame = 2;
    GetDefaultInputDeviceSampleRate(&recordFormat.mSampleRate);
    UInt32  propSize = sizeof(recordFormat);
    Error(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, NULL, &propSize, &recordFormat), "Audio Format get property failed");
    //queue = {0};
    memset(&queue, 0, sizeof(AudioQueueRef));
    
    Error(AudioQueueNewInput(&recordFormat, InputCallback, &recorder, NULL, NULL, 0, &queue), "AudioQueueNewInput failed");
    UInt32 size = sizeof(recordFormat);
    Error(AudioQueueGetProperty(queue, kAudioConverterCurrentOutputStreamDescription, &recordFormat, &size), "Could not get queue format");
    
    CFStringRef str = CFStringCreateWithCString(NULL, filename, kCFStringEncodingMacRoman);
    
    CFURLRef fileURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, str, kCFURLPOSIXPathStyle, false);
    
    Error(AudioFileCreateWithURL(fileURL,kAudioFileCAFType, &recordFormat, kAudioFileFlags_EraseFile, &recorder.recordFile), "AUdioFileCreateWithURL Failed");
    CFRelease(fileURL);
    CopyEncoderCookieToFile(queue, recorder.recordFile);
    
    int bufferByteSize = ComputeRecordBufferSize(&recordFormat, queue, 0.5);
    for(int i = 0; i < kNumberRecordBuffers; ++i) {
        
        AudioQueueBufferRef buffer;
        Error(AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer), "AudioQueueAllocateBuffer failed.");
        Error(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL), "AUdioQueueEnqueueBuffer failed");
    }
    
    recorder.running = TRUE;
    Error(AudioQueueStart(queue, NULL), "AudioQueueStart failed.");
   

}

void stopRecord() {
    recorder.running = FALSE;
    Error(AudioQueueStop(queue, TRUE), "AudioQueueStop failed");
    CopyEncoderCookieToFile(queue, recorder.recordFile);
    AudioQueueDispose(queue, TRUE);
    AudioFileClose(recorder.recordFile);
}

/*** end ***/

std::string input_name = "";
bool rec_Audio = false;
void stopCV() {
    if(renderTimer != nil && renderTimer.valid) {
        capture.release();
        if(!ac::noRecord && input_name.length() == 0) {
            if(rec_Audio == true) stopRecord();
            
        }
        if(!ac::noRecord) {
            writer.release();
            sout << "Wrote to Video File: " << ac::fileName << "\n";
        }
        
        [renderTimer invalidate];
        
        cv::destroyWindow("Acid Cam v2");
        cv::destroyWindow("Controls");
           sout << frame_cnt << " Total frames\n";
        sout << (frame_cnt/ac::fps) << " Seconds\n";
        file.close();
        // flush to log
        flushToLog(sout);
        renderTimer = nil;
        setEnabledProg();
        [controller stopCV_prog];
        if(breakProgram == true) {
            [NSApp terminate:nil];
        }
    }

}

NSTimer *renderTimer;

std::ostringstream sout;
cv::VideoWriter writer;
std::fstream file;
unsigned long file_size;
std::string add_path;

int program_main(int outputType, std::string input_file, bool noRecord, bool recAudio, std::string outputFileName, int capture_width, int capture_height, int capture_device, int frame_countx, float pass2_alpha, std::string file_path) {
    rec_Audio = recAudio;
    programRunning = true;
    sout << "Acid Cam " << ac::version << " ..\n";
    add_path="default";
    input_name = input_file;
    srand(static_cast<unsigned int>(time(0)));
    ac::translation_variable = 0.01;
    ac::tr = ac::translation_variable;
    ac::fileName = file_path+outputFileName;
    ac::noRecord = noRecord;
    ac::pass2_alpha = pass2_alpha;
    unsigned int seed = int_Seed;
    srand(seed);
    add_path = file_path;
    stopProgram = false;
    ac::tr =  0.3;
    ac::fps = 29.97;
    file_size = 0;
    try {
        if(input_file.size() == 0) capture = cv::VideoCapture(capture_device);
        else {
            capture = cv::VideoCapture(input_file);
            total_frames = capture.get(CV_CAP_PROP_FRAME_COUNT);
        }
        if (!capture.isOpened()) {
            std::cerr << "Error could not open Camera device..\n";
            return -1;
        } else
            sout << "Acid Cam " << ac::version << " Capture device opened..\n";
        int aw = capture.get(CV_CAP_PROP_FRAME_WIDTH);
        int ah = capture.get(CV_CAP_PROP_FRAME_HEIGHT);
        sout << "Resolution: " << aw << "x" << ah << "\n";
        if(ac::fps_force == false && input_file.size() != 0) ac::fps = capture.get(CV_CAP_PROP_FPS);
        sout << "FPS: " << ac::fps << "\n";
        cv::Mat frame;
        capture.read(frame);
        cv::Size frameSize = frame.size();
        if(input_file == "" && capture_width != 0 && capture_height != 0) {
            capture.set(CV_CAP_PROP_FRAME_WIDTH, capture_width);
            capture.set(CV_CAP_PROP_FRAME_HEIGHT, capture_height);
            sout << "Resolution set to " << capture_width << "x" << capture_height << "\n";
            frameSize = cv::Size(capture_width, capture_height);
        }

        setSliders(total_frames);
        
        if(ac::noRecord == false) {
            if(outputType == 0)
                writer = cv::VideoWriter(ac::fileName, CV_FOURCC('m','p','4','v'),  ac::fps, frameSize, true);
            else
                writer = cv::VideoWriter(ac::fileName, CV_FOURCC('X','V','I','D'),  ac::fps, frameSize, true);
            
            if(writer.isOpened() == false) {
                sout << "Error video file could not be created.\n";
                exit(0);
            }
            file.open(ac::fileName.c_str(), std::ios::in);
        }
        if(ac::noRecord == false)
            sout << "Now recording .. format " << ((outputType == 0) ? "MPEG-4" : "XvID") << " \n";
        else
            sout << "Recording disabled ..\n";
        cv::namedWindow("Acid Cam v2", 1);
        // flush to log
        flushToLog(sout);
        frame_cnt = 0;
        
        if(ac::noRecord == false && input_file.length() == 0 && recAudio == true) {
            std::string str_filename=ac::fileName+".caf";
            startRecord(str_filename.c_str());
        }

        
        [[NSRunLoop currentRunLoop] addTimer:renderTimer
                                     forMode:NSEventTrackingRunLoopMode];
        
       [[NSRunLoop currentRunLoop] addTimer:renderTimer
                                     forMode:NSDefaultRunLoopMode];

        return 0;
    }
    catch(std::exception &e) {
        std::cerr << e.what() << " was thrown!\n";
    }
    catch(...) {
        std::cerr << "Unknown error thrown.\n";
    }
    return 0;
}

std::ostringstream strout;
void TrackbarCallback(int pos, void *ptr) {
    ac::draw_offset = pos;
    strout << "Filter set to: " << ac::draw_strings[ac::draw_offset] << "\n";
    flushToLog(strout);
}

void IsNegativeCallback(int pos, void *ptr) {
    if(pos == 1) ac::isNegative = true;
    else ac::isNegative = false;
    strout << "isNegative: " << boolStr(ac::isNegative) << "\n";
    flushToLog(strout);
}

void IsNegativeFlash(int pos, void *ptr) {
    if(ac::switch_Back == true) {
        ac::switch_Back = false;
    } else {
        ac::switch_Back = true;
        ac::isNegative = false;
    }
    strout << "switch: " << boolStr(ac::switch_Back) << "\n" << "is Negative: " << boolStr(ac::isNegative) << "\n";
    flushToLog(strout);
}

void Pass2Enable(int pos, void *ptr) {
    if(pos == 1) ac::pass2_enabled = true;
    else ac::pass2_enabled = false;
    strout << "Pass2 Enabled: "<< boolStr(ac::pass2_enabled) <<  "\n";
    flushToLog(strout);
}

void ReverseColors(int pos, void *ptr) {
    if(pos == 1) ac::iRev = true;
    else ac::iRev = false;
    if(ac::iRev == true) ac::isNegative = true;
    strout << "Reverse Colors: " << boolStr(ac::iRev) << "\n";
    flushToLog(strout);
}

void SlideShow(int pos, void *ptr) {
    if(pos == 1) ac::slide_Show = true;
    else ac::slide_Show = false;
    strout << "Slide Show: " <<  boolStr(ac::slide_Show) << "\n";
    flushToLog(strout);
}

void SlideRand(int pos, void *ptr) {
    if(pos == 1) ac::slide_Rand = true;
    else ac::slide_Rand = false;
    strout << "Slide Show Random: " << boolStr(ac::slide_Rand) << "\n";
    flushToLog(strout);
}

void StrobeIt(int pos, void *ptr) {
    if(pos == 1) ac::strobe_It = true;
    else ac::strobe_It = false;
    strout << "Strobe It: " << boolStr(ac::strobe_It) << "\n";
    flushToLog(strout);
}

void BlurFirst(int pos, void *ptr) {
    if(pos == 1) ac::blur_First = true;
    else ac::blur_First = false;
    strout << "Blur First set to: " << boolStr(ac::blur_First) << "\n";
    flushToLog(strout);
}

void BlurSecond(int pos, void *ptr) {
    if(pos == 1) ac::blur_Second = true;
    else ac::blur_Second = false;
    strout << "Blur Second set to: " << boolStr(ac::blur_Second) << "\n";
    flushToLog(strout);
}

void ProcFrame(cv::Mat &frame) {
    static int offset = 0;
    if(ac::pass2_enabled == true)
        ac::orig_frame = frame;
    if(ac::blur_First == true) {
        cv::Mat temp;
        cv::GaussianBlur(frame, temp,cv::Size(5, 5), 0, 0, 0);
        frame = temp;
    }
    if(ac::slide_Show == false)
        ac::draw_func[ac::draw_offset](frame);
    else {
        if(ac::slide_Rand == true) ac::draw_func[rand()%ac::draw_max](frame);
        else ac::draw_func[offset](frame);
        ++offset;
        if(offset >= 7)
            offset = 0;
    }
    if(ac::switch_Back == true) {
        ac::isNegative = !ac::isNegative;
    }
    if(ac::blur_Second == true) {
        cv::Mat temp;
        cv::GaussianBlur(frame, temp,cv::Size(5, 5), 0, 0, 0);
        frame = temp;
    }
    if(ac::pass2_enabled == true) {
        ac::Pass2Blend(frame);
    }
}

void BuildImages(std::string filename) {
    std::fstream file;
    file.open(filename.c_str(), std::ios::in);
    if (!file.is_open()) {
        std::cerr << "Error opening list file: " << filename << "\n";
        exit(0);
    }
    std::vector<std::string> images;
    while (!file.eof()) {
        std::string str;
        std::getline(file, str);
        images.push_back(str);
    }
    file.close();
    if (images.size() < 4) {
        std::cerr << "Error four images are required\n";
        exit(0);
    }
    for(int i = 0; i < 4; ++i) {
        ac::image_files[i] = cv::imread(images[i]);
        if(!ac::image_files[i].data) {
            std::cerr << "Error could not load image: " << images[i] << "\n";
            exit(0);
        } else std::cout <<  images[i] << " Successfully loaded.\n";
    }
    ac::images_Enabled = true;
    std::cout << "Images enabled..\n";
}

void jumptoFrame(int frame) {
    capture.set(CV_CAP_PROP_POS_FRAMES,frame);
    frame_cnt = frame;
}

