
#include "pins_arduino.h"

#define GC_PIN 2
#define GC_PIN_DIR DDRD
// these two macros set arduino pin 2 to input or output, which with an
// external 1K pull-up resistor to the 3.3V rail, is like pulling it high or
// low.  These operations translate to 1 op code, which takes 2 cycles
#define GC_HIGH DDRD &= ~0x04
#define GC_LOW DDRD |= 0x04
#define GC_QUERY (PIND & 0x04)

#define N64_PIN 8
#define N64_HIGH DDRB &= ~0x01
#define N64_LOW DDRB |= 0x01
#define N64_QUERY (PINB & 0x01)

// 8 bytes of data that we get from the controller
struct {
    // bits: 0, 0, 0, start, y, x, b, a
    unsigned char data1;
    // bits: 1, L, R, Z, Dup, Ddown, Dright, Dleft
    unsigned char data2;
    unsigned char stick_x;
    unsigned char stick_y;
    unsigned char cstick_x;
    unsigned char cstick_y;
    unsigned char left;
    unsigned char right;
} gc_status;
char gc_raw_dump[65]; // 1 received bit per byte
char n64_raw_dump[281]; // maximum recv is 1+2+32 bytes + 1 bit

// bytes to send to the 64
// maximum we'll need to send is 33, 32 for a read request and 1 CRC byte
unsigned char n64_buffer[33];

void gc_send(unsigned char *buffer, char length);
void gc_get();
void print_gc_status();
void translate_raw_data();
void gc_to_64();
void get_n64_command();

#include "crc_table.h"

void setup()
{
  Serial.begin(9600);

  Serial.print("bit: 0x");
  Serial.println(digitalPinToBitMask(N64_PIN), HEX);
  
  Serial.print("port: 0x");
  Serial.println(digitalPinToPort(N64_PIN), HEX);

  // Status LED
  digitalWrite(13, LOW);
  pinMode(13, OUTPUT);

  // Communication with gamecube controller on this pin
  // Don't remove these lines, we don't want to push +5V to the controller
  digitalWrite(GC_PIN, LOW);  
  pinMode(GC_PIN, INPUT);

  // Communication with the N64 on this pin
  digitalWrite(N64_PIN, LOW);
  pinMode(N64_PIN, INPUT);

  
}

void translate_raw_data()
{
    // The get_gc_status function sloppily dumps its data 1 bit per byte
    // into the get_status_extended char array. It's our job to go through
    // that and put each piece neatly into the struct gc_status
    int i;
    memset(&gc_status, 0, sizeof(gc_status));
    // line 1
    // bits: 0, 0, 0, start, y, x, b a
    for (i=0; i<8; i++) {
        gc_status.data1 |= gc_raw_dump[i] ? (0x80 >> i) : 0;
    }
    // line 2
    // bits: 1, l, r, z, dup, ddown, dright, dleft
    for (i=0; i<8; i++) {
        gc_status.data2 |= gc_raw_dump[8+i] ? (0x80 >> i) : 0;
    }
    // line 3
    // bits: joystick x value
    // These are 8 bit values centered at 0x80 (128)
    for (i=0; i<8; i++) {
        gc_status.stick_x |= gc_raw_dump[16+i] ? (0x80 >> i) : 0;
    }
    for (i=0; i<8; i++) {
        gc_status.stick_y |= gc_raw_dump[24+i] ? (0x80 >> i) : 0;
    }
    for (i=0; i<8; i++) {
        gc_status.cstick_x |= gc_raw_dump[32+i] ? (0x80 >> i) : 0;
    }
    for (i=0; i<8; i++) {
        gc_status.cstick_y |= gc_raw_dump[40+i] ? (0x80 >> i) : 0;
    }
    for (i=0; i<8; i++) {
        gc_status.left |= gc_raw_dump[48+i] ? (0x80 >> i) : 0;
    }
    for (i=0; i<8; i++) {
        gc_status.right |= gc_raw_dump[56+i] ? (0x80 >> i) : 0;
    }
}

/**
 * Reads from the gc_status struct and builds a 32 bit array ready to send to
 * the N64 when it queries us.  This is stored in n64_buffer[]
 * This function is where the translation happens from gamecube buttons to N64
 * buttons
 */
void gc_to_64()
{
    // clear it out
    memset(gc_raw_dump, 0, sizeof(gc_raw_dump));
    // For reference, the bits in data1 and data2 of the gamecube struct:
    // data1: 0, 0, 0, start, y, x, b, a
    // data2: 1, L, R, Z, Dup, Ddown, Dright, Dleft

    // First byte in n64_buffer should contain:
    // A, B, Z, Start, Dup, Ddown, Dleft, Dright
    //                                                GC -> 64
    n64_buffer[0] |= (gc_status.data1 & 0x01) << 7; // A -> A
    n64_buffer[0] |= (gc_status.data1 & 0x02) << 5; // B -> B
    n64_buffer[0] |= (gc_status.data2 & 0x40) >> 1; // L -> Z
    n64_buffer[0] |= (gc_status.data1 & 0x10)     ; // S -> S
    n64_buffer[0] |= (gc_status.data2 & 0x0F)     ; // D pad

    // Second byte:
    // 0, 0, L, R, Cup, Cdown, Cleft, Cright
    n64_buffer[1] |= (gc_status.data2 & 0x10) << 1; // Z -> L (who uses N64's L?)
    n64_buffer[1] |= (gc_status.data2 & 0x20) >> 1; // R -> R

    // Optional, map the X and Y buttons to something
    // Here I chose Cleft and Cdown, since they're in relatively the same
    // location (relative to the A button), and they mean something special
    // in starfox.
    n64_buffer[1] |= (gc_status.data1 & 0x08) >> 1; // Y -> Cleft
    n64_buffer[1] |= (gc_status.data1 & 0x04)     ; // X -> Cdown

    // C buttons are tricky, translate the C stick values to determine which C
    // buttons are "pressed"
    // Analog sticks are a value 0-255 with the center at 128 the maximum and
    // minimum values seemed to vary a bit, but we only need to choose a
    // threshold here
    if (gc_status.cstick_x < 0x50) {
        // C-left
        n64_buffer[1] |= 0x02;
    }
    if (gc_status.cstick_x > 0xB0) {
        // C-right
        n64_buffer[1] |= 0x01;
    }
    if (gc_status.cstick_y < 0x50) {
        // C-down
        n64_buffer[1] |= 0x04;
    }
    if (gc_status.cstick_y > 0xB0) {
        // C-up
        n64_buffer[1] |= 0x08;
    }

    // Third byte: Control Stick X position
    n64_buffer[2] = 0x80 - gc_status.stick_x;
    
    // Fourth byte: Control Stick Y Position
    n64_buffer[3] = 0x80 - gc_status.stick_y;
}

/**
 * This sends the given byte sequence to the controller
 * length must be at least 1
 * Oh, it destroys the buffer passed in as it writes it
 */
void gc_send(unsigned char *buffer, char length)
{
    // Send these bytes
    char bits;
    
    bool bit;

    // This routine is very carefully timed by examining the assembly output.
    // Do not change any statements, it could throw the timings off
    //
    // We get 16 cycles per microsecond, which should be plenty, but we need to
    // be conservative. Most assembly ops take 1 cycle, but a few take 2
    //
    // I use manually constructed for-loops out of gotos so I have more control
    // over the outputted assembly. I can insert nops where it was impossible
    // with a for loop
    
    asm volatile (";Starting outer for loop");
outer_loop:
    {
        asm volatile (";Starting inner for loop");
        bits=8;
inner_loop:
        {
            // Starting a bit, set the line low
            asm volatile (";Setting line to low");
            GC_LOW; // 1 op, 2 cycles

            asm volatile (";branching");
            if (*buffer >> 7) {
                asm volatile (";Bit is a 1");
                // 1 bit
                // remain low for 1us, then go high for 3us
                // nop block 1
                asm volatile ("nop\nnop\nnop\nnop\nnop\n");
                
                asm volatile (";Setting line to high");
                GC_HIGH;

                // nop block 2
                // we'll wait only 2us to sync up with both conditions
                // at the bottom of the if statement
                asm volatile ("nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              );

            } else {
                asm volatile (";Bit is a 0");
                // 0 bit
                // remain low for 3us, then go high for 1us
                // nop block 3
                asm volatile ("nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\n");

                asm volatile (";Setting line to high");
                GC_HIGH;

                // wait for 1us
                asm volatile ("; end of conditional branch, need to wait 1us more before next bit");
                
            }
            // end of the if, the line is high and needs to remain
            // high for exactly 16 more cycles, regardless of the previous
            // branch path

            asm volatile (";finishing inner loop body");
            --bits;
            if (bits != 0) {
                // nop block 4
                // this block is why a for loop was impossible
                asm volatile ("nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\n");
                // rotate bits
                asm volatile (";rotating out bits");
                *buffer <<= 1;

                goto inner_loop;
            } // fall out of inner loop
        }
        asm volatile (";continuing outer loop");
        // In this case: the inner loop exits and the outer loop iterates,
        // there are /exactly/ 16 cycles taken up by the necessary operations.
        // So no nops are needed here (that was lucky!)
        --length;
        if (length != 0) {
            ++buffer;
            goto outer_loop;
        } // fall out of outer loop
    }

    // send a single stop (1) bit
    // nop block 5
    asm volatile ("nop\nnop\nnop\nnop\n");
    GC_LOW;
    // wait 1 us, 16 cycles, then raise the line 
    // 16-2=14
    // nop block 6
    asm volatile ("nop\nnop\nnop\nnop\nnop\n"
                  "nop\nnop\nnop\nnop\nnop\n"  
                  "nop\nnop\nnop\nnop\n");
    GC_HIGH;

}
/**
 * Complete copy and paste of gc_send, but with the N64
 * pin being manipulated instead.
 * I copy and pasted because I didn't want to risk the assembly
 * output being altered by passing some kind of parameter in
 * (read: I'm lazy... it probably would have worked)
 */
void n64_send(unsigned char *buffer, char length, bool wide_stop)
{
    asm volatile (";Starting N64 Send Routine");
    // Send these bytes
    char bits;
    
    bool bit;

    // This routine is very carefully timed by examining the assembly output.
    // Do not change any statements, it could throw the timings off
    //
    // We get 16 cycles per microsecond, which should be plenty, but we need to
    // be conservative. Most assembly ops take 1 cycle, but a few take 2
    //
    // I use manually constructed for-loops out of gotos so I have more control
    // over the outputted assembly. I can insert nops where it was impossible
    // with a for loop
    
    asm volatile (";Starting outer for loop");
outer_loop:
    {
        asm volatile (";Starting inner for loop");
        bits=8;
inner_loop:
        {
            // Starting a bit, set the line low
            asm volatile (";Setting line to low");
            N64_LOW; // 1 op, 2 cycles

            asm volatile (";branching");
            if (*buffer >> 7) {
                asm volatile (";Bit is a 1");
                // 1 bit
                // remain low for 1us, then go high for 3us
                // nop block 1
                asm volatile ("nop\nnop\nnop\nnop\nnop\n");
                
                asm volatile (";Setting line to high");
                N64_HIGH;

                // nop block 2
                // we'll wait only 2us to sync up with both conditions
                // at the bottom of the if statement
                asm volatile ("nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              );

            } else {
                asm volatile (";Bit is a 0");
                // 0 bit
                // remain low for 3us, then go high for 1us
                // nop block 3
                asm volatile ("nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\nnop\n"  
                              "nop\n");

                asm volatile (";Setting line to high");
                N64_HIGH;

                // wait for 1us
                asm volatile ("; end of conditional branch, need to wait 1us more before next bit");
                
            }
            // end of the if, the line is high and needs to remain
            // high for exactly 16 more cycles, regardless of the previous
            // branch path

            asm volatile (";finishing inner loop body");
            --bits;
            if (bits != 0) {
                // nop block 4
                // this block is why a for loop was impossible
                asm volatile ("nop\nnop\nnop\nnop\nnop\n"  
                              "nop\nnop\nnop\nnop\n");
                // rotate bits
                asm volatile (";rotating out bits");
                *buffer <<= 1;

                goto inner_loop;
            } // fall out of inner loop
        }
        asm volatile (";continuing outer loop");
        // In this case: the inner loop exits and the outer loop iterates,
        // there are /exactly/ 16 cycles taken up by the necessary operations.
        // So no nops are needed here (that was lucky!)
        --length;
        if (length != 0) {
            ++buffer;
            goto outer_loop;
        } // fall out of outer loop
    }

    // send a single stop (1) bit
    // nop block 5
    asm volatile ("nop\nnop\nnop\nnop\n");
    N64_LOW;
    // wait 1 us, 16 cycles, then raise the line 
    // take another 3 off for the wide_stop check
    // 16-2-3=11
    // nop block 6
    asm volatile ("nop\nnop\nnop\nnop\nnop\n"
                  "nop\nnop\nnop\nnop\nnop\n"  
                  "nop\n");
    if (wide_stop) {
        asm volatile (";another 1us for extra wide stop bit\n"
                      "nop\nnop\nnop\nnop\nnop\n"
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\n");
    }

    N64_HIGH;

}

void gc_get()
{
    // Listening for an expected 8 bytes of data from the controller and put
    // them into gc_status, an 8 byte array.
    // we put the received bytes into the array backwards, so the first byte
    // goes into slot 0.
    asm volatile (";Starting to listen");
    unsigned char timeout;
    char bitcount = 64;
    char *bitbin = gc_raw_dump;

    // Again, using gotos here to make the assembly more predictable and
    // optimization easier (please don't kill me)
read_loop:
    timeout = 0x3f;
    // wait for line to go low
    while (GC_QUERY) {
        if (!--timeout)
            return;
    }
    // wait approx 2us and poll the line
    asm volatile (
                  "nop\nnop\nnop\nnop\nnop\n"  
                  "nop\nnop\nnop\nnop\nnop\n"  
                  "nop\nnop\nnop\nnop\nnop\n"  
                  "nop\nnop\nnop\nnop\nnop\n"  
                  "nop\nnop\nnop\nnop\nnop\n"  
                  "nop\nnop\nnop\nnop\nnop\n"  
            );
    *bitbin = GC_QUERY;
    ++bitbin;
    --bitcount;
    if (bitcount == 0)
        return;

    // wait for line to go high again
    // it may already be high, so this should just drop through
    timeout = 0x3f;
    while (!GC_QUERY) {
        if (!--timeout)
            return;
    }
    goto read_loop;

}

void print_gc_status()
{
    int i;
    Serial.println();
    Serial.print("Start: ");
    Serial.println(gc_status.data1 & 0x10 ? 1:0);

    Serial.print("Y:     ");
    Serial.println(gc_status.data1 & 0x08 ? 1:0);

    Serial.print("X:     ");
    Serial.println(gc_status.data1 & 0x04 ? 1:0);

    Serial.print("B:     ");
    Serial.println(gc_status.data1 & 0x02 ? 1:0);

    Serial.print("A:     ");
    Serial.println(gc_status.data1 & 0x01 ? 1:0);

    Serial.print("L:     ");
    Serial.println(gc_status.data2 & 0x40 ? 1:0);
    Serial.print("R:     ");
    Serial.println(gc_status.data2 & 0x20 ? 1:0);
    Serial.print("Z:     ");
    Serial.println(gc_status.data2 & 0x10 ? 1:0);

    Serial.print("Dup:   ");
    Serial.println(gc_status.data2 & 0x08 ? 1:0);
    Serial.print("Ddown: ");
    Serial.println(gc_status.data2 & 0x04 ? 1:0);
    Serial.print("Dright:");
    Serial.println(gc_status.data2 & 0x02 ? 1:0);
    Serial.print("Dleft: ");
    Serial.println(gc_status.data2 & 0x01 ? 1:0);

    Serial.print("Stick X:");
    Serial.println(gc_status.stick_x, DEC);
    Serial.print("Stick Y:");
    Serial.println(gc_status.stick_y, DEC);

    Serial.print("cStick X:");
    Serial.println(gc_status.cstick_x, DEC);
    Serial.print("cStick Y:");
    Serial.println(gc_status.cstick_y, DEC);

    Serial.print("L:     ");
    Serial.println(gc_status.left, DEC);
    Serial.print("R:     ");
    Serial.println(gc_status.right, DEC);
}

bool rumble = false;
void loop()
{
    int i;

    // clear out incomming raw data buffer
    memset(gc_raw_dump, 0, sizeof(gc_raw_dump));

    // Command to send to the gamecube
    // The last bit is rumble, flip it to rumble
    // yes this does need to be inside the loop, the
    // array gets mutilated when it goes through gc_send
    unsigned char command[] = {0x40, 0x03, 0x00};
    if (rumble) {
        command[2] = 0x01;
    }

    // turn on the led, so we can visually see things are happening
    digitalWrite(13, HIGH);
    // don't want interrupts getting in the way
    noInterrupts();
    // send those 3 bytes
    gc_send(command, 3);
    // read in data and dump it to gc_raw_dump
    gc_get();
    // end of time sensitive code
    interrupts();
    digitalWrite(13, LOW);

    // translate the data in gc_raw_dump to something useful
    translate_raw_data();
    // Now translate /that/ data to the n64 byte string
    gc_to_64();

    // Wait for incomming 64 command
    // this will block until the N64 sends us a command
    noInterrupts();
    get_n64_command();

    // determine what to do by looking at bits at index 6 and 7
    // 0x00 is identify command
    // 0x01 is status
    // 0x02 is read
    // 0x03 is write
    char n64command = 0;
    n64command |= (n64_raw_dump[6] != 0) << 1;
    n64command |= (n64_raw_dump[7] != 0);
    switch ((int)n64command)
    {
        case 0x00:
            // identify
            // mutilate the n64_buffer array with our status
            // we return 0x050001 to indicate we have a rumble pack
            // or 0x050002 to indicate the expansion slot is empty
            n64_buffer[0] = 0x05;
            n64_buffer[1] = 0x00;
            n64_buffer[2] = 0x02;

            n64_send(n64_buffer, 3, 0);

            Serial.println("It was 0x00: an identify command");
            break;
        case 0x01:
            // blast out the pre-assembled array in n64_buffer
            n64_send(n64_buffer, 4, 0);

            Serial.println("It was 0x01: the query command");
            break;
        case 0x02:
            // A read. If the address is 0x8000, return 32 bytes of 0x80 bytes,
            // and a CRC byte.  this tells the system our attached controller
            // pack is a rumble pack

            // Assume it's a read for 0x8000
            // I hope memset doesn't take too long
            memset(n64_buffer, 0x80, 32);
            n64_buffer[32] = 0xB8; // CRC

            n64_send(n64_buffer, 33, 1);

            Serial.println("It was 0x02: the read command");
            break;
        case 0x03:
            // A write. we at least need to respond with a single CRC byte.  If
            // the write was to address 0xC000 and the data was 0x01, turn on
            // rumble! All other write addresses are ignored. (but we still
            // need to return a CRC)

            // decode the first data byte (fourth overall byte), bits indexed
            // at 24 through 31
            unsigned char data = 0;
            data |= (n64_raw_dump[24] != 0) << 7;
            data |= (n64_raw_dump[25] != 0) << 6;
            data |= (n64_raw_dump[26] != 0) << 5;
            data |= (n64_raw_dump[27] != 0) << 4;
            data |= (n64_raw_dump[28] != 0) << 3;
            data |= (n64_raw_dump[29] != 0) << 2;
            data |= (n64_raw_dump[30] != 0) << 1;
            data |= (n64_raw_dump[31] != 0);

            // get crc byte, invert it, as per the protocol for
            // having a memory card attached
            n64_buffer[0] = crc_repeating_table[data] ^ 0xFF;

            // send it
            n64_send(n64_buffer, 1, 1);

            // end of time critical code
            // was the address the rumble latch at 0xC000?
            // decode the first half of the address, bits
            // 8 through 15
            unsigned char addr;
            addr |= (n64_raw_dump[8] != 0) << 7;
            addr |= (n64_raw_dump[9] != 0) << 6;
            addr |= (n64_raw_dump[10] != 0) << 5;
            addr |= (n64_raw_dump[11] != 0) << 4;
            addr |= (n64_raw_dump[12] != 0) << 3;
            addr |= (n64_raw_dump[13] != 0) << 2;
            addr |= (n64_raw_dump[14] != 0) << 1;
            addr |= (n64_raw_dump[15] != 0);

            if (addr == 0xC0) {
                rumble = (data != 0);
            }

            Serial.println("It was 0x03: the write command");
            break;
    }

    interrupts();

    // DEBUG: print it
    //print_gc_status();

  
  
  delay(1000);
}

/**
  * Waits for an incomming signal on the N64 pin and reads a single
  * byte.
  * 0x00 is an identify request
  * 0x01 is a status request
  * 0x02 is a controller pack read
  * 0x03 is a controller pack write
  *
  * for 0x02 and 0x03, additional data is passed in after the command byte,
  * which is also read by this function.
  *
  * All data is raw dumped to the n64_raw_dump array, 1 bit per byte
  */
void get_n64_command()
{
    char bitcount=8;
    char *bitbin = n64_raw_dump;
    int idle_wait;

    bitcount = 9; // read the stop bit too

    // wait 32 cycles to make sure the line is idle before
    // we begin listening
    for (idle_wait=32; idle_wait>0; --idle_wait) {
        if (!N64_QUERY) {
            idle_wait = 32;
        }
    }

read_loop:
        // wait for the line to go low
        while (N64_QUERY){}

        // wait approx 2us and poll the line
        asm volatile (
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                );
        *bitbin = N64_QUERY;
        ++bitbin;
        --bitcount;
        if (bitcount == 0)
            goto read_more;

        // wait for line to go high again
        // I don't want this to execute if the loop is exiting, so
        // I couldn't use a traditional for-loop
        while (!N64_QUERY) {}
        goto read_loop;

read_more:
    if (bitbin[6]) {
        // 2 bit is on, we need to read more
        if (bitbin[7]) {
            // 1 bit is also on, the command is 0x03
            // we expect a 2 byte address and 32 bytes of data
            bitcount = 272 + 1; // 34 bytes * 8 bits per byte
            // don't forget the stop bit
        } else {
            // we expect a 2 byte address
            bitcount = 16 + 1;
        }
        // make sure the line is high. Hopefully we didn't already
        // miss the high-to-low transition
        while (!N64_QUERY) {}
read_loop2:
        // wait for the line to go low
        while (N64_QUERY){}

        // wait approx 2us and poll the line
        asm volatile (
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                      "nop\nnop\nnop\nnop\nnop\n"  
                );
        *bitbin = N64_QUERY;
        ++bitbin;
        --bitcount;
        if (bitcount == 0)
            return;

        // wait for line to go high again
        while (!N64_QUERY) {}
        goto read_loop2;
    }
}
