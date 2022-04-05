#LEAN_HOME = # May be set here
LEAN_PATH = $(LEAN_HOME)/lib/lean/:$(shell realpath src)
export LEAN_PATH

CPP = src/bump/bindings
LEAN = src/bump/auxiliary src/bump/parser src/bump/types src/bump/configparser src/bump/configconverter src/bump/io src/bump/bump

OBJS = $(shell for path in $(addsuffix .o, $(CPP) $(LEAN)); do echo $$path; done | tac)

LEANC = $(LEAN_HOME)/bin/leanc
CFLAGS = -g -Wall -fPIC -fvisibility=hidden

RES = bump

$(RES): $(addsuffix .o,$(LEAN) $(CPP))
	$(LEANC) -o $(RES) $(CFLAGS) $(OBJS)

$(addsuffix .o,$(LEAN) $(CPP)): %.o: %.cpp
	$(CXX) -c -I$(LEAN_HOME)/include $< -o $@

$(addsuffix .cpp,$(LEAN)): %.cpp: %.olean
	(cd src; $(LEAN_HOME)/bin/lean -c $(@:src/%=%) $(patsubst src/%,%,$(<:.olean=.lean)))

$(addsuffix .olean,$(LEAN)): %.olean: %.lean
	$(LEAN_HOME)/bin/lean -o $(<:.lean=.olean) $<

clean:
	rm -f $(addsuffix .cpp,$(LEAN)) $(addsuffix .olean,$(LEAN))
	rm -f $(addsuffix .o,$(LEAN)) $(addsuffix .o,$(CPP))
	rm -f $(RES)
